require "test_helper"

class Investigations::RefreshParentEnrichmentJobTest < ActiveJob::TestCase
  setup do
    @parent_article = Article.create!(
      url: "https://parent.example/seed",
      normalized_url: "https://parent.example/seed",
      host: "parent.example",
      title: "Seed article",
      body_text: "Body of the parent investigation.",
      fetch_status: :fetched,
      fetched_at: Time.current
    )
    @parent = Investigation.create!(
      submitted_url: @parent_article.url,
      normalized_url: @parent_article.normalized_url,
      root_article: @parent_article,
      status: :completed,
      analysis_completed_at: 1.hour.ago
    )
  end

  test "is a no-op when the parent has no completed children" do
    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "ignored")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher_spy.calls
    assert_equal 0, headline_spy.calls
    assert_nil @parent.reload.last_enrichment_refresh_at
  end

  test "runs enricher and honest headline when a child completes" do
    create_child(slug: "child-1", completed_at: 5.minutes.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "A more honest headline")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 1, enricher_spy.calls
    assert_equal 1, headline_spy.calls

    @parent.reload
    assert_equal "A more honest headline", @parent.honest_headline
    assert_not_nil @parent.last_enrichment_refresh_at
  end

  test "is idempotent when no new child has completed since the last refresh" do
    create_child(slug: "child-old", completed_at: 30.minutes.ago)
    @parent.update_column(:last_enrichment_refresh_at, 10.minutes.ago)
    @parent.update_column(:legacy_enrichment_applied_fingerprint, Investigations::EnrichmentLease.legacy_fingerprint(@parent))

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "should not run")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher_spy.calls, "enricher must not run when no newer child exists"
    assert_equal 0, headline_spy.calls
  end

  test "re-runs when a newer child completes after the previous refresh" do
    create_child(slug: "child-old", completed_at: 30.minutes.ago)
    @parent.update_column(:last_enrichment_refresh_at, 20.minutes.ago)
    create_child(slug: "child-new", completed_at: 1.minute.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "Updated headline")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 1, enricher_spy.calls
    assert_equal "Updated headline", @parent.reload.honest_headline
  end

  test "legacy fingerprint refreshes when an existing child summary changes" do
    child = create_child(slug: "child-summary", completed_at: 5.minutes.ago)
    enricher_spy = SpyAnalyzer.new(returns: { "composite_timeline" => "context" })
    headline_spy = SpyAnalyzer.new(returns: "headline")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
      child.update!(llm_summary: { "overall_quality" => "changed" })
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 2, enricher_spy.calls
    assert_equal 2, headline_spy.calls
  end

  test "stamps refresh timestamp even when honest headline generator returns nil" do
    create_child(slug: "child-nil-headline", completed_at: 1.minute.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: nil)

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 1, enricher_spy.calls
    assert_nil @parent.reload.honest_headline
    assert_not_nil @parent.reload.last_enrichment_refresh_at
  end

  test "does nothing for a parent that is no longer marked completed" do
    @parent.update!(status: :processing)
    create_child(slug: "child-but-parent-processing", completed_at: 1.minute.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "should not run")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher_spy.calls
    assert_equal 0, headline_spy.calls
  end

  test "grouped publication forces usable manual peers and passes proposed context to every headline computation" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    peer = create_manual_peer(group, "same-host-peer")
    rejected = create_manual_peer(group, "rejected-peer", rejected: true)
    context = { composite_timeline: "Proposed shared timeline", critical_omissions: [ "Proposed shared omission" ] }
    headline_calls = []
    enricher = SpyAnalyzer.new(returns: context)
    headline = Object.new
    headline.define_singleton_method(:call) { |**args| headline_calls << args; "headline-#{args[:investigation].slug}" }

    with_stubbed_analyzers(enricher:, headline:) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal [ @parent.id, peer.id ].sort, headline_calls.map { |call| call[:investigation].id }.sort
    assert headline_calls.all? { |call| call[:event_context] == context }
    assert_equal "Proposed shared timeline", peer.reload.event_context["composite_timeline"]
    assert_nil rejected.reload.event_context
    assert_equal group.reload.enrichment_applied_fingerprint, group.enrichment_fingerprint
  end

  test "completed auto children are forced compute inputs but never publication recipients" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    peer = create_manual_peer(group, "manual-peer")
    child = create_child(slug: "coverage-child", completed_at: Time.current)
    child.update!(auto_submitted_from: peer)
    seen = nil
    enricher = Object.new
    enricher.define_singleton_method(:call) { |**args| seen = args[:investigations].map(&:id); { "composite_timeline" => "context" } }
    headline = SpyAnalyzer.new(returns: "headline")

    with_stubbed_analyzers(enricher:, headline:) { Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id) }

    assert_includes seen, child.id
    assert_equal 2, headline.calls
    assert_nil child.reload.event_context
  end

  test "one manual member and one usable auto child synthesize once but publish only to the manual member" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    child = create_child(slug: "singleton-coverage-child", completed_at: Time.current)
    seen = nil
    enricher = Object.new
    enricher.define_singleton_method(:call) do |**args|
      seen = args[:investigations].map(&:id)
      { "composite_timeline" => "manual-and-child context" }
    end
    headline = SpyAnalyzer.new(returns: "manual headline")

    with_stubbed_analyzers(enricher:, headline:) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal [ @parent.id, child.id ].sort, seen.sort
    assert_equal 1, headline.calls
    assert_equal "manual-and-child context", @parent.reload.event_context["composite_timeline"]
    assert_equal "manual headline", @parent.honest_headline
    assert_nil child.reload.event_context
    assert_nil child.last_enrichment_refresh_at
    assert_equal 1, group.reload.enriched_revision
    assert_equal group.enrichment_fingerprint, group.enrichment_applied_fingerprint
  end

  test "singleton group acknowledges once without analyzers" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    enricher = SpyAnalyzer.new
    headline = SpyAnalyzer.new

    with_stubbed_analyzers(enricher:, headline:) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher.calls
    assert_equal 0, headline.calls
    assert_equal 1, group.reload.enriched_revision
    assert_equal group.enrichment_fingerprint, group.enrichment_applied_fingerprint
  end

  test "expired grouped lease survives enqueue outage and retry delivery is leased" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    create_manual_peer(group, "recovery-peer")
    group.update_columns(enrichment_token: "abandoned", enrichment_lease_expires_at: 1.minute.ago,
      enrichment_attempts: 1, enrichment_target_fingerprint: "target")
    original = Investigations::RefreshParentEnrichmentJob.method(:perform_later)
    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later) { |*| raise "queue down" }

    Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_enrichment)
    group.reload
    assert_nil group.enrichment_token
    assert_not_nil group.enrichment_retry_due_at
    assert_nil group.enrichment_delivery_token

    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later, original)
    assert_enqueued_with(job: Investigations::RefreshParentEnrichmentJob, args: [ @parent.id ]) do
      Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_enrichment)
    end
    assert_no_enqueued_jobs(only: Investigations::RefreshParentEnrichmentJob) do
      Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_enrichment)
    end
  ensure
    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later, original) if original
  end

  test "grouped takeover during computation publishes only the new worker output" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    peer = create_manual_peer(group, "takeover-peer")
    calls = 0
    enricher = Object.new
    enricher.define_singleton_method(:call) do |**|
      calls += 1
      if calls == 1
        group.update_columns(enrichment_lease_expires_at: Time.utc(2000, 1, 1))
        replacement = Investigations::EnrichmentLease.group_claim(group.reload)
        Investigations::EnrichmentLease.group_publish(group, replacement, { "composite_timeline" => "fresh context" },
          replacement.manual_members.to_h { |member| [ member.id, "fresh headline #{member.slug}" ] })
        { "composite_timeline" => "stale context" }
      else
        { "composite_timeline" => "fresh context" }
      end
    end
    headline = Object.new
    headline.define_singleton_method(:call) { |investigation:, **| "fresh headline #{investigation.slug}" }

    with_stubbed_analyzers(enricher:, headline:) { Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id) }

    assert_equal 1, calls
    [ @parent, peer ].each do |member|
      member.reload
      assert_equal "fresh context", member.event_context["composite_timeline"]
      assert_equal "fresh headline #{member.slug}", member.honest_headline
      assert_not_nil member.last_enrichment_refresh_at
    end
    group.reload
    assert_equal group.enrichment_fingerprint, group.enrichment_applied_fingerprint
    assert_nil group.enrichment_token
    assert_equal 1, group.enriched_revision
  end

  test "grouped final CAS rolls back every member and group state when a member write fails, then converges on retry" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    peer = create_manual_peer(group, "rollback-peer")
    claim = Investigations::EnrichmentLease.group_claim(group)
    before = [ @parent, peer ].map { |member| [ member.id, member.event_context, member.honest_headline, member.last_enrichment_refresh_at ] }
    group_before = group.reload.attributes.slice("enrichment_fingerprint", "enrichment_applied_fingerprint", "enriched_revision", "enrichment_token", "enrichment_lease_expires_at")
    original = Investigation.instance_method(:update!)
    Investigation.define_method(:update!) do |attributes = nil, &block|
      raise "second member write failed" if id == peer.id && attributes&.key?(:event_context)
      original.bind_call(self, attributes, &block)
    end

    assert_raises(RuntimeError) do
      Investigations::EnrichmentLease.group_publish(group, claim, { "composite_timeline" => "partial" }, { @parent.id => "one", peer.id => "two" })
    end
    assert_equal before, [ @parent, peer ].map { |member| member.reload; [ member.id, member.event_context, member.honest_headline, member.last_enrichment_refresh_at ] }
    assert_equal group_before, group.reload.attributes.slice(*group_before.keys)
  ensure
    Investigation.define_method(:update!, original) if original
    if claim
      travel_to(Investigations::EnrichmentLease::LEASE_FOR.from_now + 1.second) do
        retry_claim = Investigations::EnrichmentLease.group_claim(group.reload)
        assert_equal :published, Investigations::EnrichmentLease.group_publish(group, retry_claim, { "composite_timeline" => "complete" }, { @parent.id => "one", peer.id => "two" })
      end
      assert_equal "complete", peer.reload.event_context["composite_timeline"]
    end
  end

  test "group retry budget is fingerprint scoped and recovery delivers only once per delivery lease" do
    group = InvestigationGroup.create!(main_investigation: @parent)
    @parent.update!(investigation_group: group, group_membership_kind: :manual)
    peer = create_manual_peer(group, "retry-peer")
    travel_to(Time.zone.parse("2026-01-01 12:00:00 UTC")) do
      Investigations::EnrichmentLease::MAX_ATTEMPTS.times do
        claim = Investigations::EnrichmentLease.group_claim(group.reload)
        Investigations::EnrichmentLease.group_fail(group, claim, RuntimeError.new("transient"))
        travel_to(group.reload.enrichment_retry_due_at) if group.reload.enrichment_retry_due_at
      end
      assert_nil Investigations::EnrichmentLease.group_claim(group.reload)
      assert_equal Investigations::EnrichmentLease::MAX_ATTEMPTS, group.reload.enrichment_attempts
      peer.update!(llm_summary: { "overall_quality" => "changed input" })
      assert_equal 1, Investigations::EnrichmentLease.group_claim(group.reload).tap { |new_claim| Investigations::EnrichmentLease.group_fail(group, new_claim, RuntimeError.new("retry")) }.then { group.reload.enrichment_attempts }
    end
  end

  test "legacy takeover binds the completed child snapshot and stale worker cannot overwrite" do
    child = create_child(slug: "legacy-takeover", completed_at: Time.current)
    parent = @parent
    stale_claim = Investigations::EnrichmentLease.legacy_claim(parent)
    assert_equal [ parent.id, child.id ].sort, stale_claim.members.map(&:id).sort
    parent.update_columns(legacy_enrichment_lease_expires_at: Time.utc(2000, 1, 1))
    replacement = Investigations::EnrichmentLease.legacy_claim(parent.reload)
    assert_equal :published, Investigations::EnrichmentLease.legacy_publish(parent, replacement, { "composite_timeline" => "new" }, "new headline")
    assert_equal :stale, Investigations::EnrichmentLease.legacy_publish(parent, stale_claim, { "composite_timeline" => "old" }, "old headline")
    @parent.reload
    assert_equal "new", @parent.event_context["composite_timeline"]
    assert_equal "new headline", @parent.honest_headline
    assert_equal @parent.legacy_enrichment_applied_fingerprint, @parent.legacy_enrichment_target_fingerprint
  end

  test "expired legacy lease survives enqueue loss and recovery delivers one leased retry" do
    create_child(slug: "legacy-recovery", completed_at: Time.current)
    claim = Investigations::EnrichmentLease.legacy_claim(@parent)
    @parent.update_columns(legacy_enrichment_token: claim.token, legacy_enrichment_lease_expires_at: Time.utc(2000, 1, 1))
    original = Investigations::RefreshParentEnrichmentJob.method(:perform_later)
    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later) { |*| raise "queue unavailable" }

    Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_legacy_enrichment)
    @parent.reload
    assert_nil @parent.legacy_enrichment_token
    assert_not_nil @parent.legacy_enrichment_retry_due_at
    assert_nil @parent.legacy_enrichment_delivery_token

    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later, original)
    assert_enqueued_with(job: Investigations::RefreshParentEnrichmentJob, args: [ @parent.id ]) do
      Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_legacy_enrichment)
    end
    assert_no_enqueued_jobs(only: Investigations::RefreshParentEnrichmentJob) do
      Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_legacy_enrichment)
    end
  ensure
    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later, original) if original
  end

  test "legacy analyzer failure retains a durable retry and duplicate recovery triggers are idempotent" do
    create_child(slug: "legacy-failure", completed_at: Time.current)
    failing = Object.new
    failing.define_singleton_method(:call) { |**| raise "analyzer unavailable" }
    headline = SpyAnalyzer.new(returns: "unused")
    with_stubbed_analyzers(enricher: failing, headline:) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end
    @parent.reload
    assert_nil @parent.legacy_enrichment_token
    due = @parent.legacy_enrichment_retry_due_at
    assert_not_nil due

    travel_to(due + 1.second) do
      assert_enqueued_with(job: Investigations::RefreshParentEnrichmentJob, args: [ @parent.id ]) do
        Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_legacy_enrichment)
      end
      assert_no_enqueued_jobs(only: Investigations::RefreshParentEnrichmentJob) do
        Investigations::RecoverExpiredGroupLeasesJob.new.send(:recover_legacy_enrichment)
      end
    end
  end

  private

  def create_child(slug:, completed_at:)
    article = Article.create!(
      url: "https://child.example/#{slug}",
      normalized_url: "https://child.example/#{slug}",
      host: "child.example",
      title: "Child #{slug}",
      body_text: "Body.",
      fetch_status: :fetched,
      fetched_at: Time.current
    )
    Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :completed,
      analysis_completed_at: completed_at,
      auto_submitted_from_id: @parent.id
    )
  end

  class SpyAnalyzer
    attr_reader :calls
    def initialize(returns: nil)
      @returns = returns
      @calls = 0
    end
    def call(**)
      @calls += 1
      @returns
    end
  end

  def with_stubbed_analyzers(enricher:, headline:)
    original_enricher = Analyzers::CrossInvestigationEnricher.method(:call)
    original_headline = Analyzers::HonestHeadlineGenerator.method(:call)
    Analyzers::CrossInvestigationEnricher.define_singleton_method(:call) { |**args| enricher.call(**args) }
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call) { |**args| headline.call(**args) }
    yield
  ensure
    Analyzers::CrossInvestigationEnricher.define_singleton_method(:call, original_enricher)
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call, original_headline)
  end

  def create_manual_peer(group, slug, rejected: false)
    article = Article.create!(url: "https://parent.example/#{slug}", normalized_url: "https://parent.example/#{slug}",
      host: "parent.example", title: "#{slug} title", body_text: "Body", fetch_status: :fetched,
      rejection_reason: rejected ? "too short" : nil)
    Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article,
      status: :completed, analysis_completed_at: Time.current, investigation_group: group, group_membership_kind: :manual)
  end
end
