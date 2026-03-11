require "test_helper"

class Analyzers::ClaimExtractorTest < ActiveSupport::TestCase
  test "extracts headline and body claims" do
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

    assert results.any? { |r| r.role == :headline }
    assert results.any? { |r| r.role == :lead || r.role == :body }
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
end
