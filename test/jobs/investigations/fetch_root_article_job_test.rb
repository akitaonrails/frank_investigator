require "test_helper"

class Investigations::FetchRootArticleJobTest < ActiveJob::TestCase
  setup do
    @previous_fetcher = Rails.application.config.x.frank_investigator.fetcher_class
    Rails.application.config.x.frank_investigator.fetcher_class = "Fetchers::FakeFetcher"
    Fetchers::FakeFetcher.clear
  end

  teardown do
    Rails.application.config.x.frank_investigator.fetcher_class = @previous_fetcher
    Fetchers::FakeFetcher.clear
  end

  test "skips Chromium fetch when article is fresh" do
    article = Article.create!(
      url: "https://example.com/cached", normalized_url: "https://example.com/cached",
      host: "example.com", fetch_status: :fetched, fetched_at: 5.minutes.ago,
      title: "Cached article", body_text: "Already fetched content"
    )
    investigation = Investigation.create!(
      submitted_url: article.url, normalized_url: article.normalized_url,
      root_article: article, status: :processing
    )

    # No FakeFetcher registration — if Chromium is called, it will raise
    Investigations::FetchRootArticleJob.perform_now(investigation.id)

    step = investigation.pipeline_steps.find_by!(name: "fetch_root_article")
    assert_equal "completed", step.status
    assert step.result_json["cached"]
  end

  test "fetches and extracts the root article without duplicating links on rerun" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/news")

    Fetchers::FakeFetcher.register(
      "https://example.com/news",
      html: <<~HTML
        <html>
          <head>
            <title>City Hall says taxes will fall in 2026</title>
            <meta property="og:type" content="article">
            <script type="application/ld+json">{"@type": "NewsArticle", "headline": "City Hall says taxes will fall in 2026"}</script>
          </head>
          <body>
            <header><a href="https://ignore.example.com">Ignore me</a></header>
            <article>
              <h1>City Hall says taxes will fall in 2026</h1>
              <p>City Hall announced taxes will fall by 4 percent in 2026.</p>
              <p>The article cites the full budget document published by the treasury department.</p>
              <p>Officials expect the reduction to benefit over 30 million residents across the metropolitan area and surrounding regions.</p>
              <p>The full details are available in the <a href="https://example.com/budget/2026-fiscal-year-report">Budget document</a> published last week.</p>
            </article>
          </body>
        </html>
      HTML
    )

    perform_enqueued_jobs only: Investigations::KickoffJob
    Investigations::FetchRootArticleJob.perform_now(investigation.id)
    Investigations::FetchRootArticleJob.perform_now(investigation.id)

    investigation.reload

    assert_equal "fetched", investigation.root_article.fetch_status
    assert_equal 1, investigation.root_article.sourced_links.count
    assert_equal "https://example.com/budget/2026-fiscal-year-report", investigation.root_article.sourced_links.first.href
    assert_equal "completed", investigation.pipeline_steps.find_by!(name: "fetch_root_article").status
    assert_enqueued_with(job: Investigations::FetchLinkedArticleJob, args: [ investigation.id, investigation.root_article.sourced_links.first.id ]) do
      Investigations::ExpandLinkedArticlesJob.perform_now(investigation.id, source_article_id: investigation.root_article.id)
    end
  end

  test "does not fan out when fetch_root_article is already completed" do
    article = Article.create!(
      url: "https://example.com/already-fetched",
      normalized_url: "https://example.com/already-fetched",
      host: "example.com",
      fetch_status: :fetched,
      fetched_at: Time.current,
      title: "Fetched",
      body_text: "Fetched content"
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :processing
    )
    investigation.pipeline_steps.create!(name: "fetch_root_article", status: :completed, finished_at: Time.current)

    assert_no_enqueued_jobs only: [
      Investigations::ExtractClaimsJob,
      Investigations::AnalyzeHeadlineJob,
      Investigations::ExpandLinkedArticlesJob
    ] do
      Investigations::FetchRootArticleJob.perform_now(investigation.id)
    end
  end

  test "stale Chromium failure accepts a newer fetched generation without failing the step" do
    article = Article.create!(url: "https://example.com/race", normalized_url: "https://example.com/race", host: "example.com")
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article)
    GenerationRaceFetcher.on_call = lambda do |url|
      record = Article.find_by!(normalized_url: url)
      record.update!(fetch_status: :fetched, body_text: "newer successful body", title: "Newer", fetched_at: Time.current, content_generation: record.content_generation + 1)
      raise Fetchers::ChromiumFetcher::FetchError, "old browser failed"
    end
    Rails.application.config.x.frank_investigator.fetcher_class = "GenerationRaceFetcher"

    Investigations::FetchRootArticleJob.perform_now(investigation.id)

    assert_equal "completed", investigation.pipeline_steps.find_by!(name: "fetch_root_article").status
    assert_equal "newer successful body", article.reload.body_text
    assert_equal "fetched", article.fetch_status
  ensure
    GenerationRaceFetcher.on_call = nil
  end

  test "stale successful HTML accepts a newer root generation and continues pipeline fanout" do
    article = Article.create!(url: "https://example.com/success-race", normalized_url: "https://example.com/success-race", host: "example.com")
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article)
    GenerationRaceFetcher.on_call = lambda do |url|
      record = Article.find_by!(normalized_url: url)
      record.update!(fetch_status: :fetched, body_text: "newer root body", title: "Newer", fetched_at: Time.current, content_generation: record.content_generation + 1)
      Fetchers::ChromiumFetcher::Snapshot.new(html: "<html><body><article><p>#{'stale body ' * 40}</p></article></body></html>", title: "Old")
    end
    Rails.application.config.x.frank_investigator.fetcher_class = "GenerationRaceFetcher"
    assert_enqueued_with(job: Investigations::ExtractClaimsJob, args: [ investigation.id ]) { Investigations::FetchRootArticleJob.perform_now(investigation.id) }
    assert_equal "completed", investigation.pipeline_steps.find_by!(name: "fetch_root_article").status
    assert_equal "newer root body", article.reload.body_text
  ensure
    GenerationRaceFetcher.on_call = nil
  end
end

class GenerationRaceFetcher
  class << self
    attr_accessor :on_call
    def call(url) = on_call.call(url)
  end
end
