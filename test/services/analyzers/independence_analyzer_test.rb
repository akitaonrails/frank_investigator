require "test_helper"

class Analyzers::IndependenceAnalyzerTest < ActiveSupport::TestCase
  test "counts independent groups correctly" do
    a1 = create_article("https://example-a.com/1", "example-a.com", "Article about inflation rising to 8 percent this year due to supply chain issues and rising energy costs across the global economy impacting consumers.", "group_a")
    a2 = create_article("https://example-b.com/1", "example-b.com", "Article about trade policy changes affecting imports and exports in the region and how new tariffs are reshaping international commerce between major economies.", "group_b")
    a3 = create_article("https://example-c.com/1", "example-c.com", "Article about new environmental regulations passed by congress this session that will significantly impact manufacturing and energy production nationwide.", "group_c")

    result = Analyzers::IndependenceAnalyzer.call(articles: [a1, a2, a3])

    assert_equal 3, result.independent_groups_count
    assert_operator result.independence_score, :>, 0.5
    assert_empty result.penalties
  end

  test "applies single ownership cluster penalty" do
    a1 = create_article("https://globo.com/1", "g1.globo.com", "Article about inflation rising to 8 percent this year due to supply chain issues and rising energy costs across the global economy impacting consumers.", "globo.com")
    a2 = create_article("https://globo.com/2", "oglobo.globo.com", "Article about trade policy changes affecting imports and exports in the region and how new tariffs are reshaping international commerce between major economies.", "globo.com")

    MediaOwnershipGroup.create!(
      name: "Grupo Globo Test",
      owned_hosts: ["globo.com"],
      owned_independence_groups: ["globo.com"]
    )

    result = Analyzers::IndependenceAnalyzer.call(articles: [a1, a2])

    assert_equal 1, result.independent_groups_count
    assert result.penalties.any? { |p| p[:type] == "single_ownership_cluster" }
  end

  test "detects syndicated content" do
    body = "The unemployment rate fell to 3.5 percent in February according to the Bureau of Labor Statistics. " * 10
    a1 = create_article("https://site-a.com/1", "site-a.com", body, "group_a")
    a2 = create_article("https://site-b.com/1", "site-b.com", body, "group_b")

    result = Analyzers::IndependenceAnalyzer.call(articles: [a1, a2])

    assert result.syndication_detected
    assert result.penalties.any? { |p| p[:type] == "syndication_detected" }
  end

  test "detects press release propagation" do
    pr_body = "Company XYZ announces record quarterly earnings of $5 billion driven by strong demand in all segments. " * 5
    news_body = "Company XYZ announces record quarterly earnings of $5 billion driven by strong demand in all segments according to the press release. " * 5

    pr = create_article("https://prnewswire.com/1", "prnewswire.com", pr_body, "prnewswire.com")
    pr.update!(source_kind: :press_release)

    news = create_article("https://news-site.com/1", "news-site.com", news_body, "news-site.com")
    news.update!(source_kind: :news_article)

    result = Analyzers::IndependenceAnalyzer.call(articles: [pr, news])

    assert result.press_release_propagation
    assert result.penalties.any? { |p| p[:type] == "press_release_propagation" }
  end

  test "returns minimal score for empty articles" do
    result = Analyzers::IndependenceAnalyzer.call(articles: [])

    assert_equal 0, result.independent_groups_count
    assert_equal 0.05, result.independence_score
  end

  test "no syndication for genuinely different content" do
    a1 = create_article("https://site-a.com/1", "site-a.com", "The Federal Reserve raised interest rates by 25 basis points in response to persistent inflation above its target.", "group_a")
    a2 = create_article("https://site-b.com/1", "site-b.com", "Brazil's Copom raised the Selic rate to 14.25 percent citing domestic inflation pressures and global uncertainty.", "group_b")

    result = Analyzers::IndependenceAnalyzer.call(articles: [a1, a2])

    assert_not result.syndication_detected
  end

  private

  def create_article(url, host, body, group)
    Article.create!(
      url:,
      normalized_url: url,
      host:,
      body_text: body,
      fetch_status: :fetched,
      independence_group: group,
      fetched_at: Time.current
    )
  end
end
