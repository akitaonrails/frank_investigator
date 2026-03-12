require "test_helper"

class Analyzers::ClaimCanonicalizerTest < ActiveSupport::TestCase
  test "generates canonical_form and semantic_key" do
    result = Analyzers::ClaimCanonicalizer.call(text: "Brazil's GDP grew 3.1% in Q1 2025 according to IBGE")

    assert result.canonical_form.present?
    assert result.semantic_key.present?
    assert_no_match(/\s/, result.semantic_key, "semantic_key should be hyphenated, no spaces")
  end

  test "fallback semantic_key strips short words and limits length" do
    result = Analyzers::ClaimCanonicalizer.call(text: "The Brazilian economy grew by three point one percent in the first quarter")

    assert result.semantic_key.length <= 80
    refute_includes result.semantic_key, " "
  end

  test "result struct has canonical_form and semantic_key" do
    result = Analyzers::ClaimCanonicalizer::Result.new(
      canonical_form: "Brazil GDP grew 3.1% in 2025-Q1",
      semantic_key: "brazil-gdp-growth-3.1pct-2025-q1"
    )

    assert_equal "Brazil GDP grew 3.1% in 2025-Q1", result.canonical_form
    assert_equal "brazil-gdp-growth-3.1pct-2025-q1", result.semantic_key
  end

  test "call with entities and time_scope" do
    result = Analyzers::ClaimCanonicalizer.call(
      text: "Petrobras reported revenue of R$120 billion",
      entities: [{ type: "organization", value: "Petrobras" }],
      time_scope: "2024"
    )

    assert result.canonical_form.present?
    assert result.semantic_key.present?
  end
end
