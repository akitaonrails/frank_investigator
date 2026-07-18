require "test_helper"

class ReconcileGroupEvidenceJobTest < ActiveSupport::TestCase
  setup do
    clear_enqueued_jobs
    @investigation = Investigation.create!(submitted_url: "https://example.test/#{SecureRandom.hex}", normalized_url: "https://example.test/#{SecureRandom.hex}")
    @group = InvestigationGroup.create!(main_investigation: @investigation, evidence_revision: 1)
    @investigation.update!(investigation_group: @group, group_membership_kind: :manual)
  end

  test "evidence before initial summary defers and zero claims later acknowledge" do
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 0, @investigation.reload.evidence_revision_assessed

    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 1, @investigation.reload.evidence_revision_assessed
  end

  test "only one contender claims a revision and only its token can acknowledge" do
    first = Investigations::ReconciliationLease.claim(@investigation)
    assert first
    assert_nil Investigations::ReconciliationLease.claim(@investigation)
    refute Investigations::ReconciliationLease.finish!(@investigation, "other", first.revision)
    assert Investigations::ReconciliationLease.finish!(@investigation, first.token, first.revision)
    assert_equal 1, @investigation.reload.evidence_revision_assessed
  end

  test "new revision prevents old acknowledgement and the next claim converges" do
    old = Investigations::ReconciliationLease.claim(@investigation)
    @group.with_lock { @group.update!(evidence_revision: 2) }

    refute Investigations::ReconciliationLease.finish!(@investigation, old.token, old.revision)
    @investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago)
    current = Investigations::ReconciliationLease.claim(@investigation.reload)
    assert_equal 2, current.revision
    assert Investigations::ReconciliationLease.finish!(@investigation, current.token, current.revision)
    assert_equal 2, @investigation.reload.evidence_revision_assessed
  end

  test "a running or skipped required stage cannot acknowledge" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    @investigation.pipeline_steps.create!(name: "assess_claims", status: :running, started_at: Time.current)
    ClaimAssessment.create!(investigation: @investigation, claim: claim("A factual claim"))

    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 0, @investigation.reload.evidence_revision_assessed
    assert_match(/did not execute successfully/, @investigation.reconciliation_error)
  end

  test "failed passes are bounded and retain their terminal error without an enqueue loop" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    ClaimAssessment.create!(investigation: @investigation, claim: claim("Another factual claim"))
    original = Investigations::AssessClaimsJob.method(:perform_now)
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now) { |*| raise "boom" }
    4.times do |index|
      Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
      @investigation.reload.update_columns(evidence_reconciliation_retry_due_at: 1.second.ago) if index < 3
    end
  ensure
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now, original) if original

    assert_equal Investigations::ReconciliationLease::MAX_ATTEMPTS, @investigation.reload.reconciliation_attempts
    assert_match(/boom/, @investigation.reconciliation_error)
    retries = enqueued_jobs.select { |job| job[:job] == Investigations::ReconcileGroupEvidenceJob }
    assert_equal Investigations::ReconciliationLease::MAX_ATTEMPTS - 1, retries.size
    assert retries.all? { |job| job[:at].present? }
  end

  test "rhetorical failure prevents acknowledgement and uses the bounded reconciliation retry" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    ClaimAssessment.create!(investigation: @investigation, claim: claim("Rhetorical retry claim"))
    assess = Investigations::AssessClaimsJob.method(:perform_now)
    rhetorical = Investigations::AnalyzeRhetoricalStructureJob.method(:perform_now)
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now) { |*| Investigations::AssessClaimsJob::Outcome.new(executed: true, succeeded: true) }
    Investigations::AnalyzeRhetoricalStructureJob.define_singleton_method(:perform_now) { |*| raise "rhetorical unavailable" }

    4.times do |index|
      Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
      @investigation.reload.update_columns(evidence_reconciliation_retry_due_at: 1.second.ago) if index < 3
    end

    assert_equal 0, @investigation.reload.evidence_revision_assessed
    assert_equal Investigations::ReconciliationLease::MAX_ATTEMPTS, @investigation.reconciliation_attempts
    assert_match(/rhetorical unavailable/, @investigation.reconciliation_error)
  ensure
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now, assess) if assess
    Investigations::AnalyzeRhetoricalStructureJob.define_singleton_method(:perform_now, rhetorical) if rhetorical
  end

  test "an expired abandoned lease is recovered and enqueued once" do
    claim = Investigations::ReconciliationLease.claim(@investigation)
    @investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago)

    recovery = Investigations::RecoverExpiredGroupLeasesJob.new
    assert_enqueued_with(job: Investigations::ReconcileGroupEvidenceJob, args: [ @investigation.id ]) do
      def recovery.recover_fetches = nil
      recovery.perform
    end
    assert_nil @investigation.reload.reconciliation_token
    assert_no_enqueued_jobs only: Investigations::ReconcileGroupEvidenceJob do
      recovery.perform
    end
  end

  test "a recovered worker wins and the expired original cannot publish reconciliation output" do
    old = Investigations::ReconciliationLease.claim(@investigation)
    @investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago, llm_summary: { "old" => true }, honest_headline: "old", contextual_gaps: { "old" => true })
    new_claim = Investigations::ReconciliationLease.claim(@investigation.reload)

    assert_raises(Investigations::ReconciliationLease::Lost) do
      Investigations::ReconciliationLease.with_active!(@investigation, old.token, old.revision) do
        @investigation.update!(llm_summary: { "stale" => true }, honest_headline: "stale", contextual_gaps: { "stale" => true })
      end
    end
    Investigations::ReconciliationLease.with_active!(@investigation, new_claim.token, new_claim.revision) do
      @investigation.update!(llm_summary: { "winner" => true }, honest_headline: "winner", contextual_gaps: { "winner" => true })
    end
    assert_equal "winner", @investigation.reload.honest_headline
  end

  test "takeover during contextual computation publishes no stale reconciliation output or pipeline state" do
    @investigation.update!(llm_summary: { "stable" => true }, honest_headline: "stable", contextual_gaps: { "stable" => true })
    lease = Investigations::ReconciliationLease.claim(@investigation)
    original = Analyzers::ContextualGapAnalyzer.method(:call)
    takeover = nil
    Analyzers::ContextualGapAnalyzer.define_singleton_method(:call) do |investigation:|
      # This is also a lock-span assertion: claim must succeed while the analyzer runs.
      investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago)
      takeover = Investigations::ReconciliationLease.claim(investigation.reload)
      Struct.new(:gaps, :completeness_score, :summary).new([], 1.0, "new analysis")
    end

    assert_raises(Investigations::ReconciliationLease::Lost) do
      Investigations::AnalyzeContextualGapsJob.perform_now(@investigation.id, reconciliation_token: lease.token, reconciliation_revision: lease.revision)
    end
    assert takeover
    @investigation.reload
    assert_equal({ "stable" => true }, @investigation.contextual_gaps)
    assert_equal({ "stable" => true }, @investigation.llm_summary)
    assert_equal "stable", @investigation.honest_headline
    assert_nil @investigation.pipeline_steps.find_by(name: "analyze_contextual_gaps")
    assert_equal 0, @investigation.evidence_revision_assessed
    assert_equal 0, VerdictSnapshot.where(claim_assessment: @investigation.claim_assessments).count
    assert_equal 0, EvidenceItem.joins(:claim_assessment).where(claim_assessments: { investigation_id: @investigation.id }).count
    assert_nil @investigation.reconciliation_enrichment_pending_revision
  ensure
    Analyzers::ContextualGapAnalyzer.define_singleton_method(:call, original) if original
  end

  test "takeover during summary computation cannot publish summary headline confidence pipeline trigger or acknowledgement" do
    root = article("https://summary-race.test/root", "Summary race")
    @investigation.update!(root_article: root, llm_summary: { "old" => true }, honest_headline: "old", overall_confidence_score: 0.12)
    lease = Investigations::ReconciliationLease.claim(@investigation)
    generator = Investigations::GenerateSummary.method(:call)
    takeover = nil
    Investigations::GenerateSummary.define_singleton_method(:call) do |investigation:|
      investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago)
      takeover = Investigations::ReconciliationLease.claim(investigation.reload)
      Investigations::GenerateSummary::Result.new(conclusion: "new", strengths: [ "new" ], weaknesses: [], overall_quality: "strong")
    end

    assert_raises(Investigations::ReconciliationLease::Lost) do
      Investigations::GenerateSummaryJob.perform_now(@investigation.id, reconciliation_token: lease.token, reconciliation_revision: lease.revision)
    end
    assert takeover
    @investigation.reload
    assert_equal({ "old" => true }, @investigation.llm_summary)
    assert_equal "old", @investigation.honest_headline
    assert_equal 0.12, @investigation.overall_confidence_score.to_f
    assert_nil @investigation.pipeline_steps.find_by(name: "generate_summary")
    assert_nil @investigation.reconciliation_enrichment_pending_revision
    assert_equal 0, @investigation.evidence_revision_assessed
  ensure
    Investigations::GenerateSummary.define_singleton_method(:call, generator) if generator
  end

  test "takeover during assessment computation cannot write verdict snapshots or evidence items" do
    assessment = ClaimAssessment.create!(investigation: @investigation, claim: claim("Assessment race claim"))
    lease = Investigations::ReconciliationLease.claim(@investigation)
    original = Analyzers::ClaimAssessor.instance_method(:call_with_llm_result)
    investigation = @investigation
    takeover = nil
    Analyzers::ClaimAssessor.define_method(:call_with_llm_result) do |*|
      investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago)
      takeover = Investigations::ReconciliationLease.claim(investigation.reload)
      Analyzers::ClaimAssessor::Result.new(verdict: :supported, confidence_score: 0.9, checkability_status: :checkable,
        reason_summary: "new", missing_evidence_summary: nil, conflict_score: 0, authority_score: 0.9,
        independence_score: 1, timeliness_score: 1, disagreement_details: nil, unanimous: true,
        citation_depth_score: 1, primary_vetoed: false, unsubstantiated_viral: false)
    end

    assert_raises(Investigations::ReconciliationLease::Lost) do
      Investigations::AssessClaimsJob.perform_now(@investigation.id, reconciliation_token: lease.token, reconciliation_revision: lease.revision)
    end
    assert takeover
    assert_equal "pending", assessment.reload.verdict
    assert_equal 0, assessment.verdict_snapshots.count
    assert_equal 0, assessment.evidence_items.count
    assert_nil @investigation.pipeline_steps.find_by(name: "assess_claims")
  ensure
    Analyzers::ClaimAssessor.define_method(:call_with_llm_result, original) if original
  end

  test "acknowledgement records pending enrichment before enqueue and recovery delivers enqueue loss" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    original = Investigations::RefreshParentEnrichmentJob.method(:perform_later)
    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later) { |*| raise "queue unavailable" }
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 1, @investigation.reload.evidence_revision_assessed
    assert_equal 1, @investigation.reconciliation_enrichment_pending_revision
    assert_nil @investigation.reconciliation_enrichment_delivered_revision

    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later, original)
    recovery = Investigations::RecoverExpiredGroupLeasesJob.new
    def recovery.recover_fetches = nil
    assert_enqueued_with(job: Investigations::RefreshParentEnrichmentJob, args: [ @investigation.id ]) { recovery.perform }
    assert_equal 1, @investigation.reload.reconciliation_enrichment_delivered_revision
  ensure
    Investigations::RefreshParentEnrichmentJob.define_singleton_method(:perform_later, original) if original
  end

  test "a newer group revision during a full reconciliation pass cannot acknowledge the old pass" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    ClaimAssessment.create!(investigation: @investigation, claim: claim("Revision race claim"))
    assess = Investigations::AssessClaimsJob.method(:perform_now)
    contextual = Investigations::AnalyzeContextualGapsJob.method(:perform_now)
    group = @group
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now) { |*| Investigations::AssessClaimsJob::Outcome.new(executed: true, succeeded: true) }
    Investigations::AnalyzeContextualGapsJob.define_singleton_method(:perform_now) do |*|
      group.with_lock { group.update!(evidence_revision: 2) }
      Investigations::AnalyzeContextualGapsJob::Outcome.new(executed: true, succeeded: true)
    end

    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 0, @investigation.reload.evidence_revision_assessed
    assert_nil @investigation.reconciliation_enrichment_pending_revision
    assert_equal 2, @group.reload.evidence_revision
  ensure
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now, assess) if assess
    Investigations::AnalyzeContextualGapsJob.define_singleton_method(:perform_now, contextual) if contextual
  end

  test "successful reconciliation publishes every staged output and acknowledgement" do
    root = article("https://publisher.test/root", "Root headline")
    root.update!(body_text: "The agency statement is merely a conspiracy theory, the article insists.")
    evidence = article("https://records.test/evidence", "Official evidence")
    evidence.update!(source_role: :official_position)
    @investigation.update!(root_article: root)
    assessment = ClaimAssessment.create!(investigation: @investigation, claim: claim("The policy was enacted"))
    ArticleClaim.create!(article: root, claim: assessment.claim, surface_text: "The policy was enacted", stance: :repeats)
    ArticleClaim.create!(article: evidence, claim: assessment.claim, surface_text: "Official records confirm it", stance: :supports, role: :linked_source)
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    builder = Analyzers::EvidencePacketBuilder.method(:call)
    headline = Analyzers::HonestHeadlineGenerator.method(:call)
    rhetorical = Analyzers::RhetoricalFallacyAnalyzer.method(:call)
    summary = Investigations::GenerateSummary.method(:call)
    Analyzers::EvidencePacketBuilder.define_singleton_method(:call) do |investigation:, claim:|
      [ Analyzers::EvidencePacketBuilder::Entry.new(article: evidence, stance: :supports, relevance_score: 0.9, authority_score: 0.9, independence_group: evidence.host) ]
    end
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call) do |investigation:, summary_data: nil|
      raise "stale summary" unless summary_data.present?
      "Fresh honest headline"
    end
    Analyzers::RhetoricalFallacyAnalyzer.define_singleton_method(:call) do |investigation:|
      Analyzers::RhetoricalFallacyAnalyzer::Result.new(
        fallacies: [ Analyzers::RhetoricalFallacyAnalyzer::Fallacy.new(type: "delegitimizing_reframing", severity: "medium",
          excerpt: "merely a conspiracy theory", explanation: "Dismisses the official position without evaluating it.",
          undermined_claim: "The policy was enacted") ],
        narrative_bias_score: 0.4, summary: "The article substitutes a dismissive label for analysis."
      )
    end
    Investigations::GenerateSummary.define_singleton_method(:call) do |investigation:|
      raise "summary did not receive rhetorical state" unless investigation.rhetorical_analysis&.dig("fallacies")&.any? { |f| f["type"] == "delegitimizing_reframing" }
      Investigations::GenerateSummary::Result.new(conclusion: "new", strengths: [ "evidence" ], weaknesses: [], overall_quality: "mixed")
    end

    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)

    @investigation.reload
    assert_not_equal "pending", assessment.reload.verdict
    assert_predicate assessment.evidence_items, :any?
    assert @investigation.contextual_gaps.present?
    assert_includes @investigation.rhetorical_analysis.fetch("fallacies").map { |fallacy| fallacy["type"] }, "delegitimizing_reframing"
    assert_operator @investigation.overall_confidence_score.to_f, :>, 0
    assert @investigation.llm_summary.present?
    assert @investigation.honest_headline.present?
    assert_equal "completed", @investigation.pipeline_steps.find_by(name: "assess_claims").status
    assert_equal 1, @investigation.evidence_revision_assessed
    assert_equal 1, @investigation.reconciliation_enrichment_pending_revision
  ensure
    Analyzers::EvidencePacketBuilder.define_singleton_method(:call, builder) if builder
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call, headline) if headline
    Analyzers::RhetoricalFallacyAnalyzer.define_singleton_method(:call, rhetorical) if rhetorical
    Investigations::GenerateSummary.define_singleton_method(:call, summary) if summary
  end

  test "retry enqueue loss remains durable and recurring recovery redelivers it" do
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    ClaimAssessment.create!(investigation: @investigation, claim: claim("Retry delivery claim"))
    assess = Investigations::AssessClaimsJob.method(:perform_now)
    scheduler = Investigations::ReconcileGroupEvidenceJob.method(:set)
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now) { |*| raise "temporary failure" }
    Investigations::ReconcileGroupEvidenceJob.define_singleton_method(:set) do |*|
      Object.new.tap { |proxy| proxy.define_singleton_method(:perform_later) { |*| raise "queue unavailable" } }
    end
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert @investigation.reload.evidence_reconciliation_retry_due_at.present?
    assert_nil @investigation.evidence_reconciliation_retry_delivery_token

    Investigations::ReconcileGroupEvidenceJob.define_singleton_method(:set, scheduler)
    @investigation.update_columns(evidence_reconciliation_retry_due_at: 1.second.ago)
    recovery = Investigations::RecoverExpiredGroupLeasesJob.new
    def recovery.recover_fetches = nil
    assert_enqueued_with(job: Investigations::ReconcileGroupEvidenceJob, args: [ @investigation.id ]) { recovery.perform }
  ensure
    Investigations::AssessClaimsJob.define_singleton_method(:perform_now, assess) if assess
    Investigations::ReconcileGroupEvidenceJob.define_singleton_method(:set, scheduler) if scheduler
  end

  test "terminal revision attempts reset and revision N plus one fully reconciles" do
    @investigation.update!(reconciliation_attempts: Investigations::ReconciliationLease::MAX_ATTEMPTS,
      evidence_reconciliation_attempts_revision: 1, reconciliation_error: "terminal")
    @group.update!(evidence_revision: 2)
    root = article("https://revision-next.test/root", "Revision next headline")
    evidence = article("https://revision-next.test/evidence", "Revision next evidence")
    @investigation.update!(root_article: root)
    assessment = ClaimAssessment.create!(investigation: @investigation, claim: claim("Revision next claim"))
    ArticleClaim.create!(article: root, claim: assessment.claim, surface_text: "Revision next claim", stance: :repeats)
    ArticleClaim.create!(article: evidence, claim: assessment.claim, surface_text: "Evidence supports revision next claim", stance: :supports, role: :linked_source)
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    builder = Analyzers::EvidencePacketBuilder.method(:call)
    headline = Analyzers::HonestHeadlineGenerator.method(:call)
    Analyzers::EvidencePacketBuilder.define_singleton_method(:call) do |investigation:, claim:|
      [ Analyzers::EvidencePacketBuilder::Entry.new(article: evidence, stance: :supports, relevance_score: 0.9, authority_score: 0.9, independence_group: evidence.host) ]
    end
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call) { |**| "Revision next honest headline" }

    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)

    @investigation.reload
    assert_equal 2, @investigation.reload.evidence_revision_assessed
    assert_equal 0, @investigation.reconciliation_attempts
    assert_nil @investigation.reconciliation_error
    assert_not_equal "pending", assessment.reload.verdict
    assert_predicate assessment.evidence_items, :any?
    assert @investigation.contextual_gaps.present?
    assert_operator @investigation.overall_confidence_score.to_f, :>, 0
    assert @investigation.llm_summary.present?
    assert_equal "Revision next honest headline", @investigation.honest_headline
    assert_equal "completed", @investigation.pipeline_steps.find_by(name: "assess_claims").status
    assert_equal "completed", @investigation.pipeline_steps.find_by(name: "analyze_contextual_gaps").status
    assert_equal "completed", @investigation.pipeline_steps.find_by(name: "generate_summary").status
    assert_equal 2, @investigation.reconciliation_enrichment_pending_revision
  ensure
    Analyzers::EvidencePacketBuilder.define_singleton_method(:call, builder) if builder
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call, headline) if headline
  end

  private

  def claim(text)
    Claim.create!(canonical_text: text, canonical_fingerprint: Digest::SHA256.hexdigest(text), checkability_status: :checkable)
  end

  def article(url, title)
    Article.create!(url:, normalized_url: url, host: URI(url).host, title:, body_text: "Official reporting provides detailed evidence for this claim." * 10,
      excerpt: "Evidence", fetch_status: :fetched, authority_tier: :primary, authority_score: 0.9, source_kind: :government_record)
  end
end
