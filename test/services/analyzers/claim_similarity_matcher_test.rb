require "test_helper"

class Analyzers::ClaimSimilarityMatcherTest < ActiveSupport::TestCase
  test "matches identical claims" do
    claim = Claim.create!(
      canonical_text: "Unemployment fell to 3.5% in February 2026",
      canonical_fingerprint: "unemployment_test_1",
      checkability_status: :checkable
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Unemployment fell to 3.5% in February 2026",
      candidates: Claim.all
    )

    assert_equal 1, matches.length
    assert_equal claim, matches.first.claim
    assert_in_delta 1.0, matches.first.similarity_score, 0.01
  end

  test "matches paraphrased claims above threshold" do
    claim = Claim.create!(
      canonical_text: "The unemployment rate dropped to 3.5 percent in February",
      canonical_fingerprint: "unemployment_test_2",
      checkability_status: :checkable
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Unemployment rate fell to 3.5 percent in February 2026",
      candidates: Claim.all
    )

    assert matches.any?
    assert_operator matches.first.similarity_score, :>=, 0.55
  end

  test "does not match unrelated claims" do
    Claim.create!(
      canonical_text: "The stock market reached an all-time high on Tuesday",
      canonical_fingerprint: "stock_test_1",
      checkability_status: :checkable
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Inflation reached 8.5 percent in March 2026",
      candidates: Claim.all
    )

    assert_empty matches
  end

  test "returns matches sorted by similarity score" do
    Claim.create!(
      canonical_text: "GDP grew by 2.5% in the fourth quarter",
      canonical_fingerprint: "gdp_test_1",
      checkability_status: :checkable
    )
    Claim.create!(
      canonical_text: "GDP grew by 2.5% in Q4 2025 according to BLS",
      canonical_fingerprint: "gdp_test_2",
      checkability_status: :checkable
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "GDP grew by 2.5% in the fourth quarter of 2025",
      candidates: Claim.all
    )

    assert matches.any?, "Expected at least one match for similar GDP claims"
    if matches.length > 1
      assert_operator matches.first.similarity_score, :>=, matches.last.similarity_score
    end
  end

  test "returns empty for blank text" do
    matches = Analyzers::ClaimSimilarityMatcher.call(text: "", candidates: Claim.all)
    assert_empty matches
  end
end
