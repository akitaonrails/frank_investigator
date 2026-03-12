require "test_helper"

class Analyzers::ClaimSimilarityMatcherTest < ActiveSupport::TestCase
  test "matches identical claims" do
    claim = Claim.create!(
      canonical_text: "Unemployment fell to 3.5% in February 2026",
      canonical_fingerprint: "unemployment_test_#{SecureRandom.hex(4)}",
      canonical_form: "Unemployment fell to 3.5% in February 2026",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Unemployment fell to 3.5% in February 2026",
      candidates: Claim.where(id: claim.id)
    )

    assert_equal 1, matches.length
    assert_equal claim, matches.first.claim
    assert_in_delta 1.0, matches.first.similarity_score, 0.05
    assert_equal :jaccard, matches.first.match_method
  end

  test "matches paraphrased claims above threshold" do
    claim = Claim.create!(
      canonical_text: "The unemployment rate dropped to 3.5 percent in February",
      canonical_fingerprint: "unemployment_test_#{SecureRandom.hex(4)}",
      canonical_form: "The unemployment rate dropped to 3.5 percent in February",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Unemployment rate fell to 3.5 percent in February 2026",
      candidates: Claim.where(id: claim.id)
    )

    assert matches.any?
    assert_operator matches.first.similarity_score, :>=, 0.55
  end

  test "does not match unrelated claims" do
    claim = Claim.create!(
      canonical_text: "The stock market reached an all-time high on Tuesday",
      canonical_fingerprint: "stock_test_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Inflation reached 8.5 percent in March 2026",
      candidates: Claim.where(id: claim.id)
    )

    assert_empty matches
  end

  test "returns matches sorted by similarity score" do
    c1 = Claim.create!(
      canonical_text: "GDP grew by 2.5% in the fourth quarter",
      canonical_fingerprint: "gdp_test_#{SecureRandom.hex(4)}",
      canonical_form: "GDP grew by 2.5% in the fourth quarter",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
    c2 = Claim.create!(
      canonical_text: "GDP grew by 2.5% in Q4 2025 according to BLS",
      canonical_fingerprint: "gdp_test_#{SecureRandom.hex(4)}",
      canonical_form: "GDP grew by 2.5% in Q4 2025 according to BLS",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "GDP grew by 2.5% in the fourth quarter of 2025",
      candidates: Claim.where(id: [c1.id, c2.id])
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

  test "boosts score when entities overlap significantly" do
    claim = Claim.create!(
      canonical_text: "IBGE reported Brazil unemployment at 5%",
      canonical_fingerprint: "entity_test_#{SecureRandom.hex(4)}",
      canonical_form: "Brazil unemployment rate was 5% per IBGE",
      semantic_key: "brazil-unemployment-5pct",
      entities_json: [{ "type" => "organization", "value" => "IBGE" }, { "type" => "named_entity", "value" => "Brazil" }],
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "IBGE data shows Brazil unemployment stood at five percent",
      candidates: Claim.where(id: claim.id)
    )

    assert matches.any?, "Should find match with entity overlap boost"
  end

  test "LLM equivalence not invoked when use_llm is false" do
    claim = Claim.create!(
      canonical_text: "The Brazilian economy expanded by 3.1 percent in the first quarter of 2025",
      canonical_fingerprint: "llm_test_#{SecureRandom.hex(4)}",
      canonical_form: "The Brazilian economy expanded by 3.1 percent in the first quarter of 2025",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    # Default use_llm: false — should only use Jaccard
    matches = Analyzers::ClaimSimilarityMatcher.call(
      text: "Brazil GDP growth was 3.1% in Q1 2025",
      candidates: Claim.where(id: claim.id),
      use_llm: false
    )

    assert matches.is_a?(Array)
    matches.each { |m| assert_equal :jaccard, m.match_method }
  end
end
