require "test_helper"

class Investigations::GenerateSummaryJobTest < ActiveSupport::TestCase
  test "runs summary generation and stores result on investigation" do
    root = Article.create!(
      url: "https://summary.com/article", normalized_url: "https://summary.com/article",
      host: "summary.com", fetch_status: :fetched,
      body_text: "This article contains factual claims about the economy.",
      title: "Economic Report"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )
    claim = Claim.create!(canonical_text: "GDP grew 3%", canonical_fingerprint: "sum_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation:, claim:, verdict: :supported, confidence_score: 0.8, checkability_status: :checkable)

    Investigations::GenerateSummaryJob.perform_now(investigation.id)

    investigation.reload
    assert investigation.llm_summary.present?
    assert investigation.llm_summary.key?("conclusion")
    assert investigation.llm_summary.key?("overall_quality")
    assert investigation.llm_summary.key?("strengths")
    assert investigation.llm_summary.key?("weaknesses")
  end

  test "creates pipeline step" do
    root = Article.create!(
      url: "https://summary2.com/article", normalized_url: "https://summary2.com/article",
      host: "summary2.com", fetch_status: :fetched,
      body_text: "Article content.", title: "Test"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )

    Investigations::GenerateSummaryJob.perform_now(investigation.id)

    step = investigation.pipeline_steps.find_by(name: "generate_summary")
    assert_equal "completed", step.status
  end

  test "refreshes investigation status after completion" do
    root = Article.create!(
      url: "https://summary3.com/article", normalized_url: "https://summary3.com/article",
      host: "summary3.com", fetch_status: :fetched,
      body_text: "Content.", title: "Test"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )

    Investigations::GenerateSummaryJob.perform_now(investigation.id)

    step = investigation.pipeline_steps.find_by(name: "generate_summary")
    assert_equal "completed", step.status
  end
end
