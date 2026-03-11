require "test_helper"

class Investigations::RefreshStatusTest < ActiveSupport::TestCase
  test "sets completed when all required steps are done" do
    root = Article.create!(url: "https://r.com/1", normalized_url: "https://r.com/1", host: "r.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)

    Investigation::REQUIRED_STEPS.each do |step_name|
      investigation.pipeline_steps.create!(name: step_name, status: :completed, finished_at: Time.current)
    end

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "completed", investigation.status
    assert investigation.analysis_completed_at.present?
  end

  test "sets failed when any step failed" do
    root = Article.create!(url: "https://r.com/2", normalized_url: "https://r.com/2", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    investigation.pipeline_steps.create!(name: "fetch_root_article", status: :failed)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "failed", investigation.status
  end

  test "computes average confidence from assessments" do
    root = Article.create!(url: "https://r.com/3", normalized_url: "https://r.com/3", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    c1 = Claim.create!(canonical_text: "A", canonical_fingerprint: "rs_a")
    c2 = Claim.create!(canonical_text: "B", canonical_fingerprint: "rs_b")
    ClaimAssessment.create!(investigation:, claim: c1, confidence_score: 0.8)
    ClaimAssessment.create!(investigation:, claim: c2, confidence_score: 0.6)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_in_delta 0.7, investigation.overall_confidence_score, 0.01
  end

  test "sets checkability status based on claim assessments" do
    root = Article.create!(url: "https://r.com/4", normalized_url: "https://r.com/4", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    c1 = Claim.create!(canonical_text: "C", canonical_fingerprint: "rs_c")
    c2 = Claim.create!(canonical_text: "D", canonical_fingerprint: "rs_d")
    ClaimAssessment.create!(investigation:, claim: c1, checkability_status: :checkable)
    ClaimAssessment.create!(investigation:, claim: c2, checkability_status: :not_checkable)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "partially_checkable", investigation.checkability_status
  end
end
