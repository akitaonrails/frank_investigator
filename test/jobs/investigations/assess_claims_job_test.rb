require "test_helper"

class Investigations::AssessClaimsJobTest < ActiveJob::TestCase
  setup do
    @previous_llm = Rails.application.config.x.frank_investigator.llm_client_class
    Rails.application.config.x.frank_investigator.llm_client_class = "Llm::FakeClient"
    Llm::FakeClient.next_result = nil
  end

  teardown do
    Rails.application.config.x.frank_investigator.llm_client_class = @previous_llm
    Llm::FakeClient.next_result = nil
  end

  test "assesses claims and creates evidence items" do
    root = Article.create!(url: "https://example.com/assess", normalized_url: "https://example.com/assess", host: "example.com", fetch_status: :fetched, fetched_at: Time.current)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    claim = Claim.create!(canonical_text: "Inflation rose to 8 percent in March.", canonical_fingerprint: "inflation rose 8 percent march", checkability_status: :checkable)
    ArticleClaim.create!(article: root, claim:, role: :headline, surface_text: claim.canonical_text)
    ClaimAssessment.create!(investigation:, claim:)

    evidence = Article.create!(
      url: "https://bls.gov/cpi",
      normalized_url: "https://bls.gov/cpi",
      host: "bls.gov",
      title: "CPI: Inflation rose to 8 percent in March",
      body_text: "Inflation rose to 8 percent in March according to the Consumer Price Index.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97,
      independence_group: "bls.gov"
    )
    ArticleClaim.create!(article: evidence, claim:, role: :supporting, surface_text: claim.canonical_text)

    Investigations::AssessClaimsJob.perform_now(investigation.id)

    assessment = investigation.claim_assessments.first.reload
    assert_not_equal "pending", assessment.verdict
    assert_operator assessment.confidence_score, :>, 0
    assert investigation.pipeline_steps.find_by(name: "assess_claims").completed?
  end

  test "handles claims with no evidence gracefully" do
    root = Article.create!(url: "https://example.com/no-ev", normalized_url: "https://example.com/no-ev", host: "example.com", fetch_status: :fetched, fetched_at: Time.current)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    claim = Claim.create!(canonical_text: "Aliens landed in central park yesterday.", canonical_fingerprint: "aliens landed central park yesterday", checkability_status: :checkable)
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)
    ClaimAssessment.create!(investigation:, claim:)

    Investigations::AssessClaimsJob.perform_now(investigation.id)

    assessment = investigation.claim_assessments.first.reload
    assert_equal "needs_more_evidence", assessment.verdict
  end

  test "is rerunnable" do
    root = Article.create!(url: "https://example.com/rerun", normalized_url: "https://example.com/rerun", host: "example.com", fetch_status: :fetched, fetched_at: Time.current)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    claim = Claim.create!(canonical_text: "The rate is 5 percent.", canonical_fingerprint: "rate 5 percent", checkability_status: :checkable)
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)
    ClaimAssessment.create!(investigation:, claim:)

    2.times { Investigations::AssessClaimsJob.perform_now(investigation.id) }

    assert_equal 1, investigation.pipeline_steps.where(name: "assess_claims").count
  end
end
