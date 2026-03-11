require "test_helper"

class Analyzers::ClaimDecomposerTest < ActiveSupport::TestCase
  test "decomposes compound claim into atomic parts" do
    results = Analyzers::ClaimDecomposer.call(
      text: "The unemployment rate fell to 3.5% in February and the economy added 300,000 new jobs while inflation remained at 2.1 percent",
      investigation: nil
    )

    assert results.length > 1
    results.each do |r|
      assert r.canonical_text.present?
      assert r.claim_kind.present?
    end
  end

  test "keeps short simple claims intact" do
    results = Analyzers::ClaimDecomposer.call(
      text: "GDP grew by 2.5% in Q4 2025",
      investigation: nil
    )

    assert_equal 1, results.length
    assert_equal "GDP grew by 2.5% in Q4 2025", results.first.canonical_text
  end

  test "classifies quantity claims" do
    results = Analyzers::ClaimDecomposer.call(
      text: "Inflation reached 8.5 percent in March 2026",
      investigation: nil
    )

    assert_equal :quantity, results.first.claim_kind
    assert_match(/8.5 percent/, results.first.numeric_value)
  end

  test "classifies attribution claims" do
    results = Analyzers::ClaimDecomposer.call(
      text: "The president said the new policy would create one million jobs",
      investigation: nil
    )

    assert_equal :attribution, results.first.claim_kind
  end

  test "classifies causality claims" do
    results = Analyzers::ClaimDecomposer.call(
      text: "The new tariffs caused prices to rise by 15 percent across all sectors",
      investigation: nil
    )

    assert_equal :causality, results.first.claim_kind
  end

  test "classifies prediction claims" do
    results = Analyzers::ClaimDecomposer.call(
      text: "The central bank forecast expects GDP will grow 3% next year",
      investigation: nil
    )

    assert_equal :prediction, results.first.claim_kind
  end

  test "extracts speaker from attribution" do
    results = Analyzers::ClaimDecomposer.call(
      text: "According to Janet Yellen, the deficit will shrink by 2027",
      investigation: nil
    )

    assert_equal "Janet Yellen", results.first.speaker
  end

  test "extracts time scope" do
    results = Analyzers::ClaimDecomposer.call(
      text: "Unemployment fell to 3.5% in 2025",
      investigation: nil
    )

    assert_match(/2025/, results.first.time_scope)
  end

  test "extracts entities from claim" do
    results = Analyzers::ClaimDecomposer.call(
      text: "The Federal Reserve raised interest rates by 0.25 percent",
      investigation: nil
    )

    entity_values = results.first.entities.map { |e| e[:value] }
    assert entity_values.any? { |v| v.match?(/Federal Reserve/i) }
  end

  test "handles Brazilian compound claims" do
    results = Analyzers::ClaimDecomposer.call(
      text: "O IPCA subiu 0,83% em fevereiro e o desemprego caiu para 6,5% segundo o IBGE enquanto o PIB cresceu 2,1%",
      investigation: nil
    )

    assert results.length > 1
  end

  test "returns empty for blank text" do
    results = Analyzers::ClaimDecomposer.call(text: "", investigation: nil)
    assert_empty results
  end
end
