require "test_helper"

class Analyzers::ClaimAssessorTest < ActiveSupport::TestCase
  setup do
    @previous_llm_client = Rails.application.config.x.frank_investigator.llm_client_class
    Rails.application.config.x.frank_investigator.llm_client_class = "Llm::FakeClient"
    Llm::FakeClient.next_result = nil
  end

  teardown do
    Rails.application.config.x.frank_investigator.llm_client_class = @previous_llm_client
    Llm::FakeClient.next_result = nil
  end

  test "marks a claim supported when weighted primary evidence is strong" do
    root = Article.create!(url: "https://example.com/news", normalized_url: "https://example.com/news", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(canonical_text: "The budget report confirms a 4 percent tax reduction in 2026.", canonical_fingerprint: "budget report confirms 4 percent tax reduction 2026", checkability_status: :checkable)
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)

    evidence_article = Article.create!(
      url: "https://www.sec.gov/reports/budget-filing",
      normalized_url: "https://www.sec.gov/reports/budget-filing",
      host: "www.sec.gov",
      title: "Budget report confirms a 4 percent tax reduction in 2026",
      body_text: "The budget report confirms a 4 percent tax reduction in 2026.",
      excerpt: "Budget report confirms a 4 percent tax reduction in 2026.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.98,
      independence_group: "sec.gov"
    )
    ArticleClaim.create!(article: evidence_article, claim:, role: :supporting, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)

    assert_equal :supported, result.verdict
    assert_operator result.authority_score, :>=, 0.9
    assert_operator result.confidence_score, :>=, 0.5
  end

  test "marks a claim mixed when support and dispute are both strong" do
    root = Article.create!(url: "https://example.com/news-2", normalized_url: "https://example.com/news-2", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(canonical_text: "The mayor approved the measure yesterday.", canonical_fingerprint: "mayor approved measure yesterday", checkability_status: :checkable)

    supportive = Article.create!(
      url: "https://city.gov/press/measure",
      normalized_url: "https://city.gov/press/measure",
      host: "city.gov",
      title: "The mayor approved the measure yesterday",
      body_text: "The mayor approved the measure yesterday.",
      excerpt: "The mayor approved the measure yesterday.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.96,
      independence_group: "city.gov"
    )
    disputing = Article.create!(
      url: "https://records.example.net/check",
      normalized_url: "https://records.example.net/check",
      host: "records.example.net",
      title: "No evidence the mayor approved the measure yesterday",
      body_text: "There is no evidence the mayor approved the measure yesterday.",
      excerpt: "No evidence the mayor approved the measure yesterday.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      source_kind: :reference,
      authority_tier: :secondary,
      authority_score: 0.64,
      independence_group: "example.net"
    )

    ArticleClaim.create!(article: supportive, claim:, role: :supporting, surface_text: claim.canonical_text)
    ArticleClaim.create!(article: disputing, claim:, role: :supporting, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)

    assert_equal :mixed, result.verdict
    assert_operator result.conflict_score, :>, 0.5
  end
end
