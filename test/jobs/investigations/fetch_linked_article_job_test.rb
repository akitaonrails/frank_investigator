require "test_helper"

class Investigations::FetchLinkedArticleJobTest < ActiveJob::TestCase
  setup do
    @previous_fetcher = Rails.application.config.x.frank_investigator.fetcher_class
    Rails.application.config.x.frank_investigator.fetcher_class = "Fetchers::FakeFetcher"
    Fetchers::FakeFetcher.clear
  end

  teardown do
    Rails.application.config.x.frank_investigator.fetcher_class = @previous_fetcher
    Fetchers::FakeFetcher.clear
  end

  test "skips Chromium fetch for fresh linked article" do
    root = Article.create!(url: "https://example.com/root", normalized_url: "https://example.com/root", host: "example.com", fetch_status: :fetched)
    linked = Article.create!(
      url: "https://cached.example.com/report", normalized_url: "https://cached.example.com/report",
      host: "cached.example.com", fetch_status: :fetched, fetched_at: 5.minutes.ago,
      title: "Cached report", body_text: "This report confirms a 4% tax cut in 2026."
    )
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    link = ArticleLink.create!(source_article: root, target_article: linked, href: linked.normalized_url, depth: 1)

    # No FakeFetcher registration — if Chromium is called, it will raise
    assert_enqueued_with(job: Investigations::AssessClaimsJob, args: [ investigation.id ]) do
      Investigations::FetchLinkedArticleJob.perform_now(investigation.id, link.id)
    end

    link.reload
    assert_equal "crawled", link.follow_status
  end

  test "fetches a linked article and marks it crawled without extracting claims" do
    root = Article.create!(url: "https://example.com/news", normalized_url: "https://example.com/news", host: "example.com", fetch_status: :fetched)
    linked = Article.create!(url: "https://source.example.com/report", normalized_url: "https://source.example.com/report", host: "source.example.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    link = ArticleLink.create!(source_article: root, target_article: linked, href: linked.normalized_url, depth: 1)

    Fetchers::FakeFetcher.register(
      linked.normalized_url,
      html: <<~HTML
        <html>
          <head>
            <title>Budget report confirms a 4 percent tax reduction</title>
            <meta property="og:type" content="article">
            <script type="application/ld+json">{"@type": "NewsArticle", "headline": "Budget report confirms a 4 percent tax reduction"}</script>
          </head>
          <body>
            <article>
              <h1>Budget report confirms a 4 percent tax reduction</h1>
              <p>The budget report confirms a 4 percent tax reduction in 2026.</p>
              <p>According to the treasury, the policy will reduce the federal tax burden by an estimated twelve billion dollars over the next fiscal year.</p>
              <p>Economists at the central bank project a positive impact on consumer spending and employment across all sectors.</p>
              <p><a href="https://records.example.net/appendix/fiscal-data-2026">Appendix</a></p>
            </article>
          </body>
        </html>
      HTML
    )

    assert_enqueued_with(job: Investigations::AssessClaimsJob, args: [ investigation.id ]) do
      Investigations::FetchLinkedArticleJob.perform_now(investigation.id, link.id)
    end

    link.reload
    linked.reload

    assert_equal "crawled", link.follow_status
    assert_equal "fetched", linked.fetch_status
    assert linked.sourced_links.exists?(href: "https://records.example.net/appendix/fiscal-data-2026")
    # Linked articles should NOT have claims extracted — they serve as evidence only
    assert_not linked.article_claims.exists?
  end
end
