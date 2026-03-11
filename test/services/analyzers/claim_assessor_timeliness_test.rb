require "test_helper"

class Analyzers::ClaimAssessorTimelinessTest < ActiveSupport::TestCase
  setup do
    @previous_llm_client = Rails.application.config.x.frank_investigator.llm_client_class
    Rails.application.config.x.frank_investigator.llm_client_class = "Llm::FakeClient"
    Llm::FakeClient.next_result = nil
  end

  teardown do
    Rails.application.config.x.frank_investigator.llm_client_class = @previous_llm_client
    Llm::FakeClient.next_result = nil
  end

  test "uses temporal scoring when claim has timestamps" do
    root = Article.create!(url: "https://example.com/temporal-1", normalized_url: "https://example.com/temporal-1", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(
      canonical_text: "Inflation hit 5% in March 2025",
      canonical_fingerprint: "inflation hit 5 percent march 2025 temporal",
      checkability_status: :checkable,
      claim_timestamp_start: Date.new(2025, 3, 1),
      claim_timestamp_end: Date.new(2025, 3, 31)
    )
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)

    # Evidence published during claim range — should get high timeliness
    evidence = Article.create!(
      url: "https://stats.gov/cpi-march-2025",
      normalized_url: "https://stats.gov/cpi-march-2025",
      host: "stats.gov",
      title: "CPI data for March 2025",
      body_text: "Inflation hit 5% in March 2025 according to official statistics.",
      excerpt: "Inflation hit 5% in March 2025.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      published_at: Date.new(2025, 3, 20),
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.95,
      independence_group: "stats.gov"
    )
    ArticleClaim.create!(article: evidence, claim:, role: :supporting, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)
    assert_operator result.timeliness_score, :>=, 0.8, "Evidence during claim range should yield high timeliness"
  end

  test "penalizes evidence published long after claim range" do
    root = Article.create!(url: "https://example.com/temporal-2", normalized_url: "https://example.com/temporal-2", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(
      canonical_text: "GDP grew 3% in Q1 2024",
      canonical_fingerprint: "gdp grew 3 percent q1 2024 temporal",
      checkability_status: :checkable,
      claim_timestamp_start: Date.new(2024, 1, 1),
      claim_timestamp_end: Date.new(2024, 3, 31)
    )
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)

    # Evidence published 6 months after claim range
    evidence = Article.create!(
      url: "https://news.example.com/gdp-review",
      normalized_url: "https://news.example.com/gdp-review",
      host: "news.example.com",
      title: "GDP review confirms growth",
      body_text: "GDP grew 3% in Q1 2024.",
      excerpt: "GDP grew 3% in Q1 2024.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      published_at: Date.new(2024, 10, 1),
      source_kind: :news_article,
      authority_tier: :secondary,
      authority_score: 0.7,
      independence_group: "news.example.com"
    )
    ArticleClaim.create!(article: evidence, claim:, role: :supporting, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)
    assert_operator result.timeliness_score, :<=, 0.3, "Evidence far after claim range should yield low timeliness"
  end

  test "falls back to legacy timeliness when claim has no timestamps" do
    root = Article.create!(url: "https://example.com/temporal-3", normalized_url: "https://example.com/temporal-3", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(
      canonical_text: "The policy was effective.",
      canonical_fingerprint: "policy was effective temporal test",
      checkability_status: :checkable
    )
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)

    evidence = Article.create!(
      url: "https://gov.example.com/policy-report",
      normalized_url: "https://gov.example.com/policy-report",
      host: "gov.example.com",
      title: "Policy report",
      body_text: "The policy was effective according to new report.",
      excerpt: "The policy was effective.",
      fetch_status: :fetched,
      fetched_at: Time.current,
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.95,
      independence_group: "gov.example.com"
    )
    ArticleClaim.create!(article: evidence, claim:, role: :supporting, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)
    # Legacy scoring: 0.25 + (1 * 0.15) = 0.40
    assert_operator result.timeliness_score, :>=, 0.3
  end

  test "claim decomposer extracts timestamps for year scope" do
    results = Analyzers::ClaimDecomposer.call(text: "GDP grew 3% in 2024", investigation: nil)
    assert_equal Date.new(2024, 1, 1), results.first.claim_timestamp_start
    assert_equal Date.new(2024, 12, 31), results.first.claim_timestamp_end
  end

  test "claim decomposer extracts timestamps for month scope" do
    results = Analyzers::ClaimDecomposer.call(text: "Inflation hit 5% in March 2025", investigation: nil)
    assert_equal Date.new(2025, 3, 1), results.first.claim_timestamp_start
    assert_equal Date.new(2025, 3, 31), results.first.claim_timestamp_end
  end

  test "claim decomposer extracts timestamps for quarter scope" do
    results = Analyzers::ClaimDecomposer.call(text: "Revenue grew in Q2 2025", investigation: nil)
    assert_equal Date.new(2025, 4, 1), results.first.claim_timestamp_start
    assert_equal Date.new(2025, 6, 30), results.first.claim_timestamp_end
  end

  test "claim decomposer extracts timestamps for Portuguese month" do
    results = Analyzers::ClaimDecomposer.call(text: "O IPCA subiu em fevereiro 2025", investigation: nil)
    assert_equal Date.new(2025, 2, 1), results.first.claim_timestamp_start
    assert_equal Date.new(2025, 2, 28), results.first.claim_timestamp_end
  end

  test "claim decomposer extracts timestamps for Portuguese quarter" do
    results = Analyzers::ClaimDecomposer.call(text: "O PIB cresceu no primeiro trimestre de 2026", investigation: nil)
    assert_equal Date.new(2026, 1, 1), results.first.claim_timestamp_start
    assert_equal Date.new(2026, 3, 31), results.first.claim_timestamp_end
  end

  test "claim decomposer returns nil timestamps for no time scope" do
    results = Analyzers::ClaimDecomposer.call(text: "The policy was effective.", investigation: nil)
    assert_nil results.first.claim_timestamp_start
    assert_nil results.first.claim_timestamp_end
  end
end
