require "test_helper"

class Articles::SyncClaimsTest < ActiveSupport::TestCase
  test "creates canonical claims and claim assessments for an article" do
    article = Article.create!(
      url: "https://example.com/news",
      normalized_url: "https://example.com/news",
      host: "example.com",
      title: "City Hall says taxes will fall in 2026",
      body_text: "City Hall announced taxes will fall by 4 percent in 2026. Officials said the plan was approved yesterday."
    )
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article)

    Articles::SyncClaims.call(investigation:, article:)

    assert_operator Claim.count, :>=, 2
    assert_equal Claim.count, investigation.claim_assessments.count
    assert_equal article.article_claims.count, article.claims.count
  end

  test "skips claim extraction for duplicate content" do
    fingerprint = "abc123fingerprint"
    original = Article.create!(
      url: "https://example.com/original", normalized_url: "https://example.com/original",
      host: "example.com", title: "Taxes fall in 2026",
      body_text: "City Hall announced taxes will fall by 4 percent in 2026.",
      fetch_status: :fetched, body_fingerprint: fingerprint
    )
    duplicate = Article.create!(
      url: "https://mirror.com/copy", normalized_url: "https://mirror.com/copy",
      host: "mirror.com", title: "Taxes fall in 2026",
      body_text: "City Hall announced taxes will fall by 4 percent in 2026.",
      fetch_status: :fetched, body_fingerprint: fingerprint
    )
    investigation = Investigation.create!(submitted_url: original.url, normalized_url: original.normalized_url, root_article: original)

    # Sync claims for original first
    Articles::SyncClaims.call(investigation:, article: original)
    original_claims_count = Claim.count

    # Sync claims for duplicate — should skip
    Articles::SyncClaims.call(investigation:, article: duplicate)
    assert_equal original_claims_count, Claim.count
    assert_equal 0, duplicate.article_claims.count
  end
end
