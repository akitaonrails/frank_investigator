require "test_helper"

class Investigations::AnalyzeRhetoricalStructureJobTest < ActiveSupport::TestCase
  test "runs rhetorical analysis and stores result on investigation" do
    root = Article.create!(
      url: "https://rhet.com/article", normalized_url: "https://rhet.com/article",
      host: "rhet.com", fetch_status: :fetched,
      body_text: "This article presents data but then pivots to undermine it. In my 30 years of experience, this is wrong.",
      title: "Test Article"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )
    claim = Claim.create!(canonical_text: "Rhetorical test", canonical_fingerprint: "rhet_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation:, claim:, verdict: :supported, confidence_score: 0.8, checkability_status: :checkable)

    Investigations::AnalyzeRhetoricalStructureJob.perform_now(investigation.id)

    investigation.reload
    assert investigation.rhetorical_analysis.present?
    assert investigation.rhetorical_analysis.key?("fallacies")
    assert investigation.rhetorical_analysis.key?("narrative_bias_score")
    assert investigation.rhetorical_analysis.key?("summary")
  end

  test "refreshes investigation status after completion" do
    root = Article.create!(
      url: "https://rhet2.com/article", normalized_url: "https://rhet2.com/article",
      host: "rhet2.com", fetch_status: :fetched,
      body_text: "Simple factual content without rhetorical issues.",
      title: "Clean Article"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )

    Investigations::AnalyzeRhetoricalStructureJob.perform_now(investigation.id)

    step = investigation.pipeline_steps.find_by(name: "analyze_rhetorical_structure")
    assert_equal "completed", step.status
  end

  test "reconciliation publishes rhetorical output only while its lease remains active" do
    root = Article.create!(url: "https://rhet-race.test/article", normalized_url: "https://rhet-race.test/article",
      host: "rhet-race.test", fetch_status: :fetched, body_text: "Officials called it a conspiracy theory.", title: "Dismissal")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root,
      rhetorical_analysis: { "stable" => true })
    group = InvestigationGroup.create!(main_investigation: investigation, evidence_revision: 1)
    investigation.update!(investigation_group: group, group_membership_kind: :manual)
    lease = Investigations::ReconciliationLease.claim(investigation)
    analyzer = Analyzers::RhetoricalFallacyAnalyzer.method(:call)
    takeover = nil

    Analyzers::RhetoricalFallacyAnalyzer.define_singleton_method(:call) do |investigation:|
      investigation.update_columns(reconciliation_lease_expires_at: 1.second.ago)
      takeover = Investigations::ReconciliationLease.claim(investigation.reload)
      Analyzers::RhetoricalFallacyAnalyzer::Result.new(fallacies: [], narrative_bias_score: 0.0, summary: "new")
    end

    assert_raises(Investigations::ReconciliationLease::Lost) do
      Investigations::AnalyzeRhetoricalStructureJob.perform_now(investigation.id,
        reconciliation_token: lease.token, reconciliation_revision: lease.revision)
    end
    assert takeover
    assert_equal({ "stable" => true }, investigation.reload.rhetorical_analysis)
    assert_nil investigation.pipeline_steps.find_by(name: "analyze_rhetorical_structure")
  ensure
    Analyzers::RhetoricalFallacyAnalyzer.define_singleton_method(:call, analyzer) if analyzer
  end

  test "a running rhetorical stage is not successful during reconciliation" do
    root = Article.create!(url: "https://rhet-running.test/article", normalized_url: "https://rhet-running.test/article",
      host: "rhet-running.test", fetch_status: :fetched, body_text: "Text", title: "Running")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    group = InvestigationGroup.create!(main_investigation: investigation, evidence_revision: 1)
    investigation.update!(investigation_group: group, group_membership_kind: :manual)
    investigation.pipeline_steps.create!(name: "analyze_rhetorical_structure", status: :running, started_at: Time.current)
    lease = Investigations::ReconciliationLease.claim(investigation)

    outcome = Investigations::AnalyzeRhetoricalStructureJob.perform_now(investigation.id,
      reconciliation_token: lease.token, reconciliation_revision: lease.revision)

    refute outcome.executed
    refute outcome.succeeded
    assert_equal 0, investigation.reload.evidence_revision_assessed
  end
end
