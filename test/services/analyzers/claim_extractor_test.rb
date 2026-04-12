require "test_helper"

class Analyzers::ClaimExtractorTest < ActiveSupport::TestCase
  test "extracts claims from article" do
    article = Article.create!(
      url: "https://example.com/extractor",
      normalized_url: "https://example.com/extractor",
      host: "example.com",
      title: "Government announces 15 percent increase in minimum wage",
      body_text: "The government announced a 15 percent increase in minimum wage effective next year. " \
                 "Workers across the country will benefit from the change. " \
                 "The labor ministry confirmed the decision was unanimous.",
      fetch_status: :fetched
    )

    results = Analyzers::ClaimExtractor.call(article)

    assert results.any?, "Should extract at least one claim"
    assert results.all? { |r| r.surface_text.present? }
    assert results.all? { |r| r.checkability_status.present? }
  end

  test "returns empty for blank body" do
    article = Article.create!(
      url: "https://example.com/empty",
      normalized_url: "https://example.com/empty",
      host: "example.com",
      title: nil,
      body_text: nil,
      fetch_status: :fetched
    )

    results = Analyzers::ClaimExtractor.call(article)
    assert_empty results
  end

  test "deduplicates claims by fingerprint" do
    article = Article.create!(
      url: "https://example.com/dedup",
      normalized_url: "https://example.com/dedup",
      host: "example.com",
      title: "The tax rate is now 5 percent nationwide.",
      body_text: "The tax rate is now 5 percent nationwide. Officials confirmed the change.",
      fetch_status: :fetched
    )

    results = Analyzers::ClaimExtractor.call(article)
    fingerprints = results.map { |r| Analyzers::ClaimFingerprint.call(r.canonical_text) }
    assert_equal fingerprints.uniq.size, fingerprints.size
  end

  test "falls back to heuristic when LLM unavailable" do
    original_key = ENV.delete("OPENROUTER_API_KEY")

    article = Article.create!(
      url: "https://example.com/heuristic",
      normalized_url: "https://example.com/heuristic",
      host: "example.com",
      title: "Congress passes major infrastructure bill worth $500 billion",
      body_text: "The United States Congress passed a major infrastructure bill today. " \
                 "The bill allocates $500 billion for roads, bridges, and broadband. " \
                 "President signed the bill into law at a ceremony.",
      fetch_status: :fetched
    )

    results = Analyzers::ClaimExtractor.call(article)

    assert results.any? { |r| r.role == :headline }, "Heuristic should extract headline"
    assert results.any? { |r| r.role == :lead || r.role == :body }, "Heuristic should extract body"
  ensure
    ENV["OPENROUTER_API_KEY"] = original_key if original_key
  end

  test "heuristic fallback deprioritizes off-topic side sentences" do
    original_key = ENV.delete("OPENROUTER_API_KEY")

    article = Article.create!(
      url: "https://example.com/side-topic",
      normalized_url: "https://example.com/side-topic",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "Haddad foi elogiado por aliados ao comentar politica fiscal. " \
                 "O texto discute Haddad, impostos e resultado fiscal. " \
                 "Daniel Vorcaro apareceu em um episodio lateral sem relacao com a tese central.",
      fetch_status: :fetched
    )

    results = Analyzers::ClaimExtractor.call(article)

    refute results.any? { |result| result.canonical_text.include?("Daniel Vorcaro") }
  ensure
    ENV["OPENROUTER_API_KEY"] = original_key if original_key
  end
end
