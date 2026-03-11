require "test_helper"

class Analyzers::EvidenceRelationshipAnalyzerTest < ActiveSupport::TestCase
  test "supports when article body overlaps significantly with claim" do
    claim = Claim.create!(canonical_text: "Inflation rose to 8 percent in March", canonical_fingerprint: "era_support", checkability_status: :checkable)
    article = Article.create!(
      url: "https://a.com/era1", normalized_url: "https://a.com/era1", host: "a.com",
      title: "CPI report",
      body_text: "Inflation rose to 8 percent in March according to official data from the bureau.",
      fetch_status: :fetched
    )

    result = Analyzers::EvidenceRelationshipAnalyzer.call(claim:, article:)
    assert_equal :supports, result.stance
    assert_operator result.relevance_score, :>, 0
  end

  test "disputes when negation patterns are present" do
    claim = Claim.create!(canonical_text: "The mayor approved the budget yesterday", canonical_fingerprint: "era_dispute", checkability_status: :checkable)
    article = Article.create!(
      url: "https://a.com/era2", normalized_url: "https://a.com/era2", host: "a.com",
      title: "Budget dispute",
      body_text: "There is no evidence the mayor approved the budget yesterday. Officials denied the claim.",
      fetch_status: :fetched
    )

    result = Analyzers::EvidenceRelationshipAnalyzer.call(claim:, article:)
    assert_equal :disputes, result.stance
  end

  test "contextualizes when overlap is low" do
    claim = Claim.create!(canonical_text: "Tax revenue increased by 20 percent", canonical_fingerprint: "era_context", checkability_status: :checkable)
    article = Article.create!(
      url: "https://a.com/era3", normalized_url: "https://a.com/era3", host: "a.com",
      title: "Economic overview",
      body_text: "The economy showed mixed signals across multiple sectors this quarter.",
      fetch_status: :fetched
    )

    result = Analyzers::EvidenceRelationshipAnalyzer.call(claim:, article:)
    assert_equal :contextualizes, result.stance
  end

  test "returns zero relevance for no overlap" do
    claim = Claim.create!(canonical_text: "Mars rover found water", canonical_fingerprint: "era_zero", checkability_status: :checkable)
    article = Article.create!(
      url: "https://a.com/era4", normalized_url: "https://a.com/era4", host: "a.com",
      title: "Cooking recipes",
      body_text: "Here are the best chocolate cake recipes for beginners.",
      fetch_status: :fetched
    )

    result = Analyzers::EvidenceRelationshipAnalyzer.call(claim:, article:)
    assert_equal 0, result.relevance_score
  end
end
