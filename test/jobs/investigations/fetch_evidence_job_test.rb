require "test_helper"

class FetchEvidenceJobTest < ActiveSupport::TestCase
  HTML = <<~HTML.freeze
    <html><head><title>Official evidence</title><meta property="og:type" content="article"><script type="application/ld+json">{"@type":"NewsArticle","headline":"Official evidence"}</script></head><body><article><h1>Official evidence</h1><p>#{"This is substantive evidence about a documented public event and its official record. " * 12}</p></article></body></html>
  HTML

  setup do
    clear_enqueued_jobs
    @investigation = Investigation.create!(submitted_url: "https://news.test/#{SecureRandom.hex}", normalized_url: "https://news.test/#{SecureRandom.hex}")
    @group = InvestigationGroup.create!(main_investigation: @investigation)
    @investigation.update!(investigation_group: @group, group_membership_kind: :manual)
    @article = Article.create!(url: "https://www.whitehouse.gov/briefing-room/test-#{SecureRandom.hex}", normalized_url: "https://www.whitehouse.gov/briefing-room/test-#{SecureRandom.hex}", host: "www.whitehouse.gov")
    @source = InvestigationGroupEvidenceSource.create!(investigation_group: @group, article: @article, submitted_url: @article.url)
    @original_fetcher = Rails.application.config.x.frank_investigator.fetcher_class
    Rails.application.config.x.frank_investigator.fetcher_class = "EvidenceFetchTestFetcher"
    EvidenceFetchTestFetcher.html = HTML
    EvidenceFetchTestFetcher.error = nil
    EvidenceFetchTestFetcher.on_call = nil
    EvidenceFetchTestFetcher.calls = 0
  end

  teardown { Rails.application.config.x.frank_investigator.fetcher_class = @original_fetcher }

  test "fetches explicit evidence without creating an investigation and advances revision once" do
    assert_difference -> { HtmlSnapshot.count }, 1 do
      Investigations::FetchEvidenceJob.perform_now(@source.id)
    end
    assert_equal "ready", @source.reload.status
    assert_equal 1, @group.reload.evidence_revision
    assert_equal "secondary", @article.reload.authority_tier
    assert_equal "official_position", @article.source_role
    assert_equal 0, Investigation.where(normalized_url: @article.normalized_url).count
    assert_enqueued_with(job: Investigations::ReconcileGroupEvidenceJob, args: [ @investigation.id ])
  end

  test "same fingerprint is idempotent and a changed fingerprint advances exactly once" do
    Investigations::FetchEvidenceJob.perform_now(@source.id)
    @source.reload.update!(status: :pending, fetch_retry_due_at: nil, fetch_delivery_token: nil, fetch_delivery_expires_at: nil)
    Investigations::FetchEvidenceJob.perform_now(@source.id)
    assert_equal 1, @group.reload.evidence_revision
    @source.reload.update!(status: :pending, fetch_retry_due_at: nil, fetch_delivery_token: nil, fetch_delivery_expires_at: nil)
    staged = Articles::PersistFetchedContent.prepare(article: @article.reload, html: HTML.sub("</article>", "<p>New independently substantive evidence changes the durable content fingerprint.</p></article>"), fetched_title: "Official evidence", current_depth: 0, evidence: true)
    changed_fingerprint = staged.assessment_fingerprint
    refute_equal @source.reload.content_fingerprint, changed_fingerprint
    token = Investigations::EvidenceFetchLease.claim!(@source)
    assert Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, staged)
    assert_equal "ready", @source.reload.status, @source.last_error_message
    assert_equal changed_fingerprint, @source.content_fingerprint
    assert_equal 2, @group.reload.evidence_revision
  end

  test "public refresh keeps a matching fingerprint stable and advances exactly once for changed content" do
    Investigations::FetchEvidenceJob.perform_now(@source.id)
    initial_generation = @source.reload.fetch_attempts_generation
    assert_equal 1, @group.reload.evidence_revision

    @source.reset_for_refresh!
    same_generation = @source.reload.fetch_attempts_generation
    refute_equal initial_generation, same_generation
    Investigations::FetchEvidenceJob.perform_now(@source.id)
    assert_equal "ready", @source.reload.status
    assert_equal 1, @group.reload.evidence_revision

    EvidenceFetchTestFetcher.html = HTML.sub("</article>", "<p>A changed official record adds material evidence.</p></article>")
    @source.reset_for_refresh!
    refute_equal same_generation, @source.reload.fetch_attempts_generation
    Investigations::FetchEvidenceJob.perform_now(@source.id)
    assert_equal "ready", @source.reload.status
    assert_equal 2, @group.reload.evidence_revision
  end

  test "staged successful evidence loses to a newer shared article publication without side effects" do
    winner_html = HTML.sub("</article>", "<p>Winning shared publication is the newer authoritative record.</p></article>")
    original = Investigations::FetchEvidenceJob.instance_method(:publish!)
    published_winner = false
    Investigations::FetchEvidenceJob.define_method(:publish!) do |source, token, staged|
      unless published_winner
        published_winner = true
        Articles::PersistFetchedContent.call(article: source.article.reload, html: winner_html, fetched_title: "Winner", current_depth: 0)
      end
      original.bind_call(self, source, token, staged)
    end

    Investigations::FetchEvidenceJob.perform_now(@source.id)

    winner = @article.reload
    assert_includes winner.body_text, "Winning shared publication"
    assert_equal "Official evidence", winner.title
    assert_equal "pending", @source.reload.status
    assert_nil @source.content_fingerprint
    assert_equal 0, @group.reload.evidence_revision
    assert_equal 1, HtmlSnapshot.where(article: winner).count
    assert_equal 0, winner.sourced_links.count
  ensure
    Investigations::FetchEvidenceJob.define_method(:publish!, original) if original
  end

  test "two independently claimed sources publish into one group without losing either revision" do
    other_article = Article.create!(url: "https://www.whitehouse.gov/briefing-room/other-#{SecureRandom.hex}", normalized_url: "https://www.whitehouse.gov/briefing-room/other-#{SecureRandom.hex}", host: "www.whitehouse.gov")
    other_source = InvestigationGroupEvidenceSource.create!(investigation_group: @group, article: other_article, submitted_url: other_article.url)
    first = Articles::PersistFetchedContent.prepare(article: @article, html: HTML, fetched_title: "First", current_depth: 0, evidence: true)
    second_html = HTML.sub("</article>", "<p>A distinct second official record supplies independent evidence.</p></article>")
    second = Articles::PersistFetchedContent.prepare(article: other_article, html: second_html, fetched_title: "Second", current_depth: 0, evidence: true)
    first_token = Investigations::EvidenceFetchLease.claim!(@source)
    second_token = Investigations::EvidenceFetchLease.claim!(other_source)

    assert Investigations::FetchEvidenceJob.new.send(:publish!, @source, first_token, first)
    assert Investigations::FetchEvidenceJob.new.send(:publish!, other_source, second_token, second)
    assert_equal 2, @group.reload.evidence_revision
    assert_equal "ready", @source.reload.status
    assert_equal "ready", other_source.reload.status
    refute_equal @source.content_fingerprint, other_source.content_fingerprint

    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    Investigations::RecoverExpiredGroupLeasesJob.perform_now
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 2, @investigation.reload.evidence_revision_assessed
  end

  test "public evidence fetch and reconciliation produce a relevant assessed evidence item and refreshed report" do
    root = Article.create!(url: "https://news.test/root-#{SecureRandom.hex}", normalized_url: "https://news.test/root-#{SecureRandom.hex}", host: "news.test", title: "Policy enacted", body_text: "The policy was enacted according to the official record. " * 8, fetch_status: :fetched, fetched_at: Time.current)
    @investigation.update!(root_article: root)
    claim = Claim.create!(canonical_text: "The policy was enacted", canonical_fingerprint: SecureRandom.hex, checkability_status: :checkable)
    assessment = ClaimAssessment.create!(investigation: @investigation, claim:)
    ArticleClaim.create!(article: root, claim:, surface_text: claim.canonical_text, stance: :repeats)
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)

    Investigations::FetchEvidenceJob.perform_now(@source.id)
    ArticleClaim.create!(article: @article.reload, claim:, surface_text: "The official record confirms the policy was enacted", stance: :supports, role: :linked_source)
    builder = Analyzers::EvidencePacketBuilder.method(:call)
    headline = Analyzers::HonestHeadlineGenerator.method(:call)
    evidence_article = @article
    Analyzers::EvidencePacketBuilder.define_singleton_method(:call) do |investigation:, claim:|
      [ Analyzers::EvidencePacketBuilder::Entry.new(article: evidence_article, stance: :supports, relevance_score: 0.95,
        authority_score: evidence_article.authority_score, independence_group: evidence_article.host) ]
    end
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call) { |**| "Evidence-backed policy headline" }
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)

    @investigation.reload
    item = assessment.reload.evidence_items.find_by!(article: @article)
    assert_equal @article.normalized_url, item.source_url
    assert_not_equal "pending", assessment.verdict
    assert_operator @investigation.overall_confidence_score.to_f, :>, 0
    assert @investigation.contextual_gaps.present?
    assert @investigation.llm_summary.present?
    assert @investigation.honest_headline.present?
    assert_equal "completed", @investigation.pipeline_steps.find_by!(name: "assess_claims").status
    assert_equal @group.reload.evidence_revision, @investigation.evidence_revision_assessed
    assert_equal @group.evidence_revision, @investigation.reconciliation_enrichment_pending_revision
  ensure
    Analyzers::EvidencePacketBuilder.define_singleton_method(:call, builder) if builder
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call, headline) if headline
  end

  test "expired lease becomes durable delivery once and stale token cannot publish" do
    old = Investigations::EvidenceFetchLease.claim!(@source)
    @source.update_columns(fetch_lease_expires_at: 1.second.ago)
    recovery = Investigations::RecoverExpiredGroupLeasesJob.new
    recovery.perform
    assert_equal "pending", @source.reload.status
    assert @source.fetch_delivery_token.present?
    refute Investigations::EvidenceFetchLease.active?(@source, old)
    assert_no_difference -> { @group.reload.evidence_revision } do
      assert_equal false, Investigations::FetchEvidenceJob.new.send(:publish!, @source, old,
        Articles::PersistFetchedContent.prepare(article: @article, html: HTML, fetched_title: "Official evidence", current_depth: 0, evidence: true))
    end
  end

  test "browser work taken over after lease expiry cannot overwrite the winning publication" do
    original_body = @article.body_text
    winner_html = HTML.sub("</article>", "<p>Winning official evidence establishes the newer record with a <a href=\"https://records.test/winning\">primary record</a>.</p></article>")
    EvidenceFetchTestFetcher.on_call = lambda do |url|
      if EvidenceFetchTestFetcher.calls.zero?
        EvidenceFetchTestFetcher.calls += 1
        @source.reload.update_columns(fetch_lease_expires_at: 1.second.ago)
        EvidenceFetchTestFetcher.html = winner_html
        Investigations::FetchEvidenceJob.perform_now(@source.id)
        Fetchers::ChromiumFetcher::Snapshot.new(html: HTML, title: "Old evidence")
      else
        EvidenceFetchTestFetcher.calls += 1
        Fetchers::ChromiumFetcher::Snapshot.new(html: EvidenceFetchTestFetcher.html, title: "Winning evidence")
      end
    end

    Investigations::FetchEvidenceJob.perform_now(@source.id)

    assert_equal "ready", @source.reload.status
    assert_equal 1, @group.reload.evidence_revision
    assert_includes @article.reload.body_text, "Winning official evidence"
    refute_equal original_body, @article.body_text
    assert_equal Articles::PersistFetchedContent.prepare(article: @article, html: winner_html, fetched_title: "Winning evidence", current_depth: 0, evidence: true).assessment_fingerprint, @source.content_fingerprint
    assert_equal "secondary", @article.authority_tier
    assert_equal "official_position", @article.source_role
    assert_equal [ "https://records.test/winning" ], @article.sourced_links.pluck(:href)
    assert_equal 1, HtmlSnapshot.where(article: @article).count
  ensure
    EvidenceFetchTestFetcher.on_call = nil
  end

  test "transient failures persist bounded retry and reset is intentional" do
    EvidenceFetchTestFetcher.error = Fetchers::ChromiumFetcher::FetchError.new("timeout")
    Investigations::FetchEvidenceJob.perform_now(@source.id)
    assert_equal "pending", @source.reload.status
    assert @source.fetch_retry_due_at.present?
    @source.update_columns(fetch_retry_due_at: 1.second.ago)
    3.times { Investigations::FetchEvidenceJob.perform_now(@source.id); @source.reload.update_columns(fetch_retry_due_at: 1.second.ago) }
    assert_equal "failed", @source.reload.status
    @source.reset_fetch_failure!
    assert_equal "pending", @source.reload.status
    assert_equal 0, @source.attempts_count
  end

  test "repeated lease expiry stops at exactly the bounded attempt budget" do
    travel_to Time.zone.parse("2026-07-17 12:00:00 UTC") do
      Investigations::EvidenceFetchLease::MAX_ATTEMPTS.times do |attempt|
        token = Investigations::EvidenceFetchLease.claim!(@source)
        assert token
        @source.update_columns(fetch_lease_expires_at: 1.second.ago)
        Investigations::RecoverExpiredGroupLeasesJob.perform_now
        @source.reload
        if attempt + 1 == Investigations::EvidenceFetchLease::MAX_ATTEMPTS
          assert_equal "failed", @source.status
        else
          assert_equal "pending", @source.status
          assert @source.fetch_retry_due_at
        end
      end
    end
    assert_equal Investigations::EvidenceFetchLease::MAX_ATTEMPTS, @source.reload.attempts_count
    assert_nil Investigations::EvidenceFetchLease.claim!(@source)
    assert_no_enqueued_jobs only: Investigations::FetchEvidenceJob do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
  end

  test "retry enqueue outage preserves durable retry state and later delivers once" do
    @source.update!(fetch_retry_due_at: 1.second.ago)

    original = Investigations::FetchEvidenceJob.method(:perform_later)
    Investigations::FetchEvidenceJob.define_singleton_method(:perform_later) { |*| raise "queue unavailable" }
    begin
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    ensure
      Investigations::FetchEvidenceJob.define_singleton_method(:perform_later, original)
    end
    @source.reload
    assert_equal "pending", @source.status
    assert @source.fetch_retry_due_at <= Time.current
    assert_nil @source.fetch_delivery_token

    assert_enqueued_with(job: Investigations::FetchEvidenceJob, args: [ @source.id ]) do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
    delivery_token = @source.reload.fetch_delivery_token
    assert delivery_token
    assert_no_enqueued_jobs only: Investigations::FetchEvidenceJob do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
    assert_equal delivery_token, @source.reload.fetch_delivery_token
  end

  test "ready evidence whose reconciliation enqueue is lost is periodically redelivered and acknowledged" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    original = Investigations::ReconcileGroupEvidenceJob.method(:perform_later)
    Investigations::ReconcileGroupEvidenceJob.define_singleton_method(:perform_later) { |*| raise "queue unavailable" }
    assert_raises(RuntimeError) { Investigations::FetchEvidenceJob.perform_now(@source.id) }
    assert_equal "ready", @source.reload.status
    assert_equal 1, @group.reload.evidence_revision
    assert_equal 0, @investigation.reload.evidence_revision_assessed

    Investigations::ReconcileGroupEvidenceJob.define_singleton_method(:perform_later, original)
    assert_enqueued_with(job: Investigations::ReconcileGroupEvidenceJob, args: [ @investigation.id ]) do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal @group.reload.evidence_revision, @investigation.reload.evidence_revision_assessed
  ensure
    Investigations::ReconcileGroupEvidenceJob.define_singleton_method(:perform_later, original) if original
  end

  test "terminal rejection records its reason without publishing article side effects or a revision" do
    before = @article.attributes.slice("body_text", "source_role", "authority_tier", "content_generation")
    EvidenceFetchTestFetcher.html = "<html><body>too short</body></html>"

    assert_no_difference [ -> { HtmlSnapshot.count }, -> { ArticleLink.count }, -> { @group.reload.evidence_revision } ] do
      Investigations::FetchEvidenceJob.perform_now(@source.id)
    end

    assert_equal "rejected", @source.reload.status
    assert_not_nil @source.last_error_message
    assert_equal before, @article.reload.attributes.slice(*before.keys)
  end

  test "resetting failed and rejected sources gives each a fresh public fetch budget" do
    [ :failed, :rejected ].each do |terminal|
      old_generation = SecureRandom.uuid
      @source.update!(status: terminal, attempts_count: Investigations::EvidenceFetchLease::MAX_ATTEMPTS,
        fetch_attempts_generation: old_generation, terminal_at: Time.current, ready_at: Time.current)
      @source.reset_fetch_failure!
      @source.reload
      assert_equal "pending", @source.status
      assert_equal 0, @source.attempts_count
      refute_equal old_generation, @source.fetch_attempts_generation
      assert_nil @source.terminal_at
      assert_nil @source.ready_at
      Investigations::FetchEvidenceJob.perform_now(@source.id)
      assert_equal "ready", @source.reload.status
    end
  end

  test "stale rejected evidence cannot publish a terminal source outcome" do
    token = Investigations::EvidenceFetchLease.claim!(@source)
    rejected = Articles::PersistFetchedContent.prepare(article: @article.reload, html: "<html><body>too short</body></html>", fetched_title: "short", current_depth: 0, evidence: true)
    @article.update!(body_text: "newer durable content", fetch_status: :fetched, headline_divergence_score: 0.77, content_generation: @article.content_generation + 1)

    assert_raises(Articles::PersistFetchedContent::StaleGeneration) do
      Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, rejected)
    end
    assert_equal "fetching", @source.reload.status
    assert_equal 0, @group.reload.evidence_revision
    assert_equal "newer durable content", @article.reload.body_text
    assert_equal 0.77, @article.headline_divergence_score.to_f
  end

  test "strict evidence snapshot failure rolls back article source and revision" do
    token = Investigations::EvidenceFetchLease.claim!(@source)
    staged = Articles::PersistFetchedContent.prepare(article: @article.reload, html: HTML, fetched_title: "Official evidence", current_depth: 0, evidence: true)
    original = HtmlSnapshot.method(:store!)
    HtmlSnapshot.define_singleton_method(:store!) { |**| raise "snapshot storage unavailable" }

    assert_raises(RuntimeError) { Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, staged) }
    assert_nil @article.reload.body_text
    assert_equal "fetching", @source.reload.status
    assert_equal 0, @group.reload.evidence_revision
  ensure
    HtmlSnapshot.define_singleton_method(:store!, original) if original
  end

  test "late evidence-source publication failure atomically rolls back article links snapshot and revision" do
    token = Investigations::EvidenceFetchLease.claim!(@source)
    html = HTML.sub("</article>", "<p>See the <a href=\"https://records.test/late\">late record</a>.</p></article>")
    staged = Articles::PersistFetchedContent.prepare(article: @article.reload, html:, fetched_title: "Official evidence", current_depth: 0, evidence: true)
    before_article = @article.attributes.slice("body_text", "content_generation", "authority_tier", "source_role", "fetch_status")
    original = @source.method(:update!)
    @source.define_singleton_method(:update!) do |attributes|
      raise "late source update failed" if attributes[:status] == :ready
      original.call(attributes)
    end

    assert_raises(RuntimeError) { Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, staged) }
    assert_equal before_article, @article.reload.attributes.slice(*before_article.keys)
    assert_equal 0, @article.sourced_links.count
    assert_equal 0, HtmlSnapshot.where(article: @article).count
    assert_equal "fetching", @source.reload.status
    assert_nil @source.content_fingerprint
    assert_equal 0, @group.reload.evidence_revision
  ensure
    @source.define_singleton_method(:update!, original) if original
  end

  test "classification-only assessment fingerprint advances once" do
    first = Articles::PersistFetchedContent.prepare(article: @article.reload, html: HTML, fetched_title: "Official evidence", current_depth: 0, evidence: true)
    token = Investigations::EvidenceFetchLease.claim!(@source)
    Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, first)
    changed_metadata = Sources::AuthorityClassifier::Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.99, independence_group: "changed", source_role: :authenticated_legal_text)
    changed = Articles::PersistFetchedContent::Staged.new(first.extracted, first.connector_result, changed_metadata, first.html, first.fetched_title, first.current_depth, nil, @article.reload.content_generation, true)
    @source.reload.update!(status: :pending)
    token = Investigations::EvidenceFetchLease.claim!(@source)
    Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, changed)
    assert_equal 2, @group.reload.evidence_revision
    @source.reload.update!(status: :pending)
    token = Investigations::EvidenceFetchLease.claim!(@source)
    Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, changed.with(content_generation: @article.reload.content_generation))
    assert_equal 2, @group.reload.evidence_revision
  end

  test "title-only assessment change advances once and publication clears old divergence" do
    @article.update!(headline_divergence_score: 0.91)
    first = Articles::PersistFetchedContent.prepare(article: @article.reload, html: HTML, fetched_title: "Official evidence", current_depth: 0, evidence: true)
    token = Investigations::EvidenceFetchLease.claim!(@source)
    Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, first)
    assert_nil @article.reload.headline_divergence_score
    @source.reload.update!(status: :pending)
    title_html = HTML.sub("<title>Official evidence</title>", "<title>Corrected official evidence</title>")
    titled = Articles::PersistFetchedContent.prepare(article: @article.reload, html: title_html, fetched_title: "Official evidence", current_depth: 0, evidence: true)
    refute_equal first.assessment_fingerprint, titled.assessment_fingerprint
    token = Investigations::EvidenceFetchLease.claim!(@source)
    Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, titled)
    assert_equal 2, @group.reload.evidence_revision
    @source.reload.update!(status: :pending)
    token = Investigations::EvidenceFetchLease.claim!(@source)
    Investigations::FetchEvidenceJob.new.send(:publish!, @source, token, titled.with(content_generation: @article.reload.content_generation))
    assert_equal 2, @group.reload.evidence_revision
  end

  test "intentional reset clears terminal state and preserves only ready comparison fingerprint" do
    @source.update!(status: :failed, attempts_count: 4, terminal_at: Time.current, ready_at: Time.current, content_fingerprint: "old", last_error_message: "bad")
    old_generation = @source.fetch_attempts_generation
    @source.reset_for_refresh!
    assert_nil @source.reload.content_fingerprint
    assert_nil @source.ready_at
    refute_equal old_generation, @source.fetch_attempts_generation
    @source.update!(status: :ready, content_fingerprint: "keep", ready_at: Time.current)
    @source.reset_for_refresh!
    assert_equal "keep", @source.reload.content_fingerprint
    assert_nil @source.ready_at
    assert_equal 0, @source.attempts_count
  end
end

class EvidenceFetchTestFetcher
  class << self
    attr_accessor :html, :error, :on_call, :calls
    def call(*)
      return on_call.call(*) if on_call
      raise error if error
      Fetchers::ChromiumFetcher::Snapshot.new(html: self.html, title: "Official evidence")
    end
  end
end
