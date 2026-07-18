require "test_helper"

class HonestHeadlineGeneratorTest < ActiveSupport::TestCase
  test "staged symbol-keyed summary values are included in the headline prompt" do
    article = Article.create!(
      url: "https://headline-prompt.test/story", normalized_url: "https://headline-prompt.test/story",
      host: "headline-prompt.test", title: "Original headline", fetch_status: :fetched
    )
    investigation = Investigation.create!(
      submitted_url: article.url, normalized_url: article.normalized_url,
      root_article: article, llm_summary: { "overall_quality" => "weak", "weaknesses" => [ "persisted weakness" ] }
    )

    generator = Analyzers::HonestHeadlineGenerator.new(
      investigation:,
      summary_data: { overall_quality: "strong", weaknesses: [ "fresh staged weakness" ] }
    )
    prompt = JSON.parse(generator.send(:build_prompt, article))

    assert_equal "strong", prompt["summary_quality"]
    assert_equal [ "fresh staged weakness" ], prompt["summary_weaknesses"]
    refute_includes prompt["summary_weaknesses"], "persisted weakness"
  end

  test "proposed symbol-keyed event context is normalized into the headline prompt" do
    article = Article.create!(url: "https://headline-event.test/story", normalized_url: "https://headline-event.test/story",
      host: "headline-event.test", title: "Original headline", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article)

    prompt = JSON.parse(Analyzers::HonestHeadlineGenerator.new(investigation:,
      event_context: { composite_timeline: "Proposed timeline", critical_omissions: [ "Proposed omission" ] }).send(:build_prompt, article))

    assert_equal "Proposed timeline", prompt.dig("event_context", "composite_timeline")
    assert_equal [ "Proposed omission" ], prompt.dig("event_context", "critical_omissions")
  end
end
