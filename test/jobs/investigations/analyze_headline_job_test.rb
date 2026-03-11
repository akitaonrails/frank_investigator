require "test_helper"

class Investigations::AnalyzeHeadlineJobTest < ActiveJob::TestCase
  test "scores headline bait and updates investigation" do
    article = Article.create!(
      url: "https://example.com/headline-test",
      normalized_url: "https://example.com/headline-test",
      host: "example.com",
      title: "SHOCKING: Government DESTROYS economy with tax plan",
      body_text: "The government passed a modest tax adjustment affecting certain brackets.",
      fetch_status: :fetched,
      fetched_at: Time.current
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :processing
    )

    Investigations::AnalyzeHeadlineJob.perform_now(investigation.id)
    investigation.reload

    assert_operator investigation.headline_bait_score, :>, 0
    assert investigation.pipeline_steps.find_by(name: "analyze_headline").completed?
  end

  test "handles missing root article" do
    investigation = Investigation.create!(
      submitted_url: "https://example.com/no-root-hl",
      normalized_url: "https://example.com/no-root-hl",
      status: :processing
    )

    assert_raises(RuntimeError) do
      Investigations::AnalyzeHeadlineJob.perform_now(investigation.id)
    end
  end
end
