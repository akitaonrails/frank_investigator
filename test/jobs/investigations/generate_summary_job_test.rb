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

  test "enqueues RefreshParentEnrichmentJob when the investigation has a parent" do
    parent_article = Article.create!(
      url: "https://parent.example/seed", normalized_url: "https://parent.example/seed",
      host: "parent.example", fetch_status: :fetched,
      body_text: "Parent body.", title: "Parent"
    )
    parent = Investigation.create!(
      submitted_url: parent_article.url, normalized_url: parent_article.normalized_url,
      root_article: parent_article, status: :completed, analysis_completed_at: 1.hour.ago
    )

    child_article = Article.create!(
      url: "https://child.example/article", normalized_url: "https://child.example/article",
      host: "child.example", fetch_status: :fetched,
      body_text: "Child body content.", title: "Child"
    )
    child = Investigation.create!(
      submitted_url: child_article.url, normalized_url: child_article.normalized_url,
      root_article: child_article, status: :processing,
      auto_submitted_from_id: parent.id
    )
    Claim.create!(canonical_text: "Child claim", canonical_fingerprint: "child_#{SecureRandom.hex(4)}", checkability_status: :checkable).tap do |c|
      ClaimAssessment.create!(investigation: child, claim: c, verdict: :supported, confidence_score: 0.7, checkability_status: :checkable)
    end

    assert_enqueued_with(job: Investigations::RefreshParentEnrichmentJob, args: [ parent.id ]) do
      Investigations::GenerateSummaryJob.perform_now(child.id)
    end
  end

  test "does not enqueue RefreshParentEnrichmentJob when there is no parent" do
    article = Article.create!(
      url: "https://lonely.example/article", normalized_url: "https://lonely.example/article",
      host: "lonely.example", fetch_status: :fetched,
      body_text: "Body.", title: "Lonely"
    )
    investigation = Investigation.create!(
      submitted_url: article.url, normalized_url: article.normalized_url,
      root_article: article, status: :processing
    )

    assert_no_enqueued_jobs(only: Investigations::RefreshParentEnrichmentJob) do
      Investigations::GenerateSummaryJob.perform_now(investigation.id)
    end
  end
end
