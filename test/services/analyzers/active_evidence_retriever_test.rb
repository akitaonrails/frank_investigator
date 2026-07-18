require "test_helper"

class Analyzers::ActiveEvidenceRetrieverTest < ActiveSupport::TestCase
  setup do
    @root = Article.create!(
      url: "https://news.com/aer1", normalized_url: "https://news.com/aer1",
      host: "news.com", fetch_status: :fetched
    )
    @investigation = Investigation.create!(
      submitted_url: @root.url, normalized_url: @root.normalized_url, root_article: @root
    )
    @claim = Claim.create!(
      canonical_text: "Congress passed bill H.R.1234 to fund infrastructure",
      canonical_fingerprint: "aer_congress_test",
      checkability_status: :checkable
    )
    ArticleClaim.create!(article: @root, claim: @claim, role: :body, surface_text: @claim.canonical_text)
    @previous_fetcher = Rails.application.config.x.frank_investigator.fetcher_class
    Rails.application.config.x.frank_investigator.fetcher_class = "Fetchers::FakeFetcher"
    # Ensure LLM is unavailable so LlmSearchQueryGenerator falls back
    @original_api_key = ENV["OPENROUTER_API_KEY"]
    ENV.delete("OPENROUTER_API_KEY")
  end

  teardown do
    Rails.application.config.x.frank_investigator.fetcher_class = @previous_fetcher
    Fetchers::FakeFetcher.clear
    ENV["OPENROUTER_API_KEY"] = @original_api_key if @original_api_key
  end

  test "returns an array from call" do
    results = Analyzers::ActiveEvidenceRetriever.call(investigation: @investigation, claim: @claim)
    assert results.is_a?(Array)
  end

  test "respects MAX_FETCHES_PER_CLAIM limit" do
    claim = Claim.create!(
      canonical_text: "The CPI inflation rate rose 3 percent according to BLS statistics and the FRED index showed GDP growth",
      canonical_fingerprint: "aer_multi_query",
      checkability_status: :checkable
    )
    ArticleClaim.create!(article: @root, claim:, role: :body, surface_text: claim.canonical_text)

    Fetchers::FakeFetcher.register(
      /./,
      "<html><head><title>Result</title></head><body><p>Some content about CPI inflation rate statistics data analysis for testing purposes.</p></body></html>",
      "Search Result"
    )

    results = Analyzers::ActiveEvidenceRetriever.call(investigation: @investigation, claim:)
    assert results.length <= Analyzers::ActiveEvidenceRetriever::MAX_FETCHES_PER_CLAIM
  end

  test "builds search queries from LlmSearchQueryGenerator and AuthorityQueryGenerator" do
    retriever = Analyzers::ActiveEvidenceRetriever.new(investigation: @investigation, claim: @claim)
    queries = retriever.send(:build_search_queries)

    assert queries.is_a?(Array)
    assert queries.any?, "Should generate at least one search query"
    assert queries.all? { |q| q.is_a?(String) }, "All queries should be strings"
    assert queries.size <= 5, "Should return at most 5 queries"
  end

  test "creates ArticleClaim links for fetched articles" do
    article_url = "https://apnews.com/article/congress-infrastructure-bill-hr1234-bipartisan"
    article_html = "<html><head><title>AP News</title></head><body><p>Congress infrastructure bill HR 1234 passed with bipartisan support for roads.</p></body></html>"
    Fetchers::FakeFetcher.register(/apnews\.com/, article_html, "AP News")

    # Pre-create article as if WebSearcher found it
    article = Article.create!(
      url: article_url,
      normalized_url: Investigations::UrlNormalizer.call(article_url),
      host: "apnews.com",
      fetch_status: :pending
    )

    retriever = Analyzers::ActiveEvidenceRetriever.new(investigation: @investigation, claim: @claim)
    retriever.send(:link_to_claim, article)
    link = ArticleClaim.find_by(article:, claim: @claim)
    assert_not_nil link, "Should create ArticleClaim link"
    assert_equal "linked_source", link.role
  end

  test "skips URLs already linked to claim" do
    existing_url = "https://www.reuters.com/existing-article-about-topic"
    Article.create!(
      url: existing_url, normalized_url: existing_url,
      host: "www.reuters.com", fetch_status: :fetched
    ).tap do |article|
      ArticleClaim.create!(article:, claim: @claim, role: :linked_source, surface_text: @claim.canonical_text)
    end

    retriever = Analyzers::ActiveEvidenceRetriever.new(investigation: @investigation, claim: @claim)
    linked_urls = retriever.send(:existing_linked_urls)

    assert linked_urls.include?(existing_url), "Should track existing linked URLs"
  end

  test "stale fetch failure cannot replace a newer fetched generation" do
    url = "https://race.example/evidence"
    article = Article.create!(url:, normalized_url: url, host: "race.example", fetch_status: :pending)
    ActiveEvidenceGenerationRaceFetcher.on_call = lambda do |fetch_url|
      record = Article.find_by!(normalized_url: fetch_url)
      record.update!(fetch_status: :fetched, title: "New evidence", body_text: "Newer fetched content", fetched_at: Time.current, content_generation: record.content_generation + 1)
      raise "stale browser failure"
    end
    Rails.application.config.x.frank_investigator.fetcher_class = "ActiveEvidenceGenerationRaceFetcher"

    retriever = Analyzers::ActiveEvidenceRetriever.new(investigation: @investigation, claim: @claim)
    assert_nil retriever.send(:fetch_and_persist, url, "Old evidence")

    assert_equal "fetched", article.reload.fetch_status
    assert_equal "Newer fetched content", article.body_text
  ensure
    ActiveEvidenceGenerationRaceFetcher.on_call = nil
  end
end

class ActiveEvidenceGenerationRaceFetcher
  class << self
    attr_accessor :on_call

    def new = self
    def call(url) = on_call.call(url)
  end
end
