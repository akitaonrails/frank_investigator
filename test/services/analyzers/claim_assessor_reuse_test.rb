require "test_helper"

class Analyzers::ClaimAssessorReuseTest < ActiveSupport::TestCase
  setup do
    @previous_llm = Rails.application.config.x.frank_investigator.llm_client_class
    Rails.application.config.x.frank_investigator.llm_client_class = "Llm::FakeClient"
    Llm::FakeClient.next_result = nil
  end

  teardown do
    Rails.application.config.x.frank_investigator.llm_client_class = @previous_llm
    Llm::FakeClient.next_result = nil
  end

  test "reuses prior assessment from another investigation" do
    claim = Claim.create!(canonical_text: "GDP grew by 3 percent in 2025", canonical_fingerprint: "reuse_gdp", checkability_status: :checkable)

    # Create a prior investigation with a completed assessment
    prior_root = Article.create!(url: "https://a.com/prior", normalized_url: "https://a.com/prior", host: "a.com", fetch_status: :fetched)
    prior_inv = Investigation.create!(submitted_url: prior_root.url, normalized_url: prior_root.normalized_url, root_article: prior_root)
    ClaimAssessment.create!(
      investigation: prior_inv,
      claim:,
      verdict: :supported,
      confidence_score: 0.82,
      checkability_status: :checkable,
      reason_summary: "Multiple government sources confirm GDP growth.",
      missing_evidence_summary: "Additional quarter-over-quarter data would help.",
      authority_score: 0.75,
      independence_score: 0.56,
      timeliness_score: 0.6,
      conflict_score: 0.05
    )

    # Now assess in a new investigation
    new_root = Article.create!(url: "https://b.com/new", normalized_url: "https://b.com/new", host: "b.com", fetch_status: :fetched)
    new_inv = Investigation.create!(submitted_url: new_root.url, normalized_url: new_root.normalized_url, root_article: new_root)
    ArticleClaim.create!(article: new_root, claim:, role: :body, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation: new_inv, claim:)

    assert_equal :supported, result.verdict
    # Reused assessments get a small confidence discount
    assert_operator result.confidence_score, :<, 0.82
    assert_includes result.reason_summary, "prior investigation"
  end

  test "does not reuse low-confidence prior assessments" do
    claim = Claim.create!(canonical_text: "Moon is made of cheese confirmed", canonical_fingerprint: "reuse_low", checkability_status: :checkable)

    prior_root = Article.create!(url: "https://a.com/prlow", normalized_url: "https://a.com/prlow", host: "a.com", fetch_status: :fetched)
    prior_inv = Investigation.create!(submitted_url: prior_root.url, normalized_url: prior_root.normalized_url, root_article: prior_root)
    ClaimAssessment.create!(
      investigation: prior_inv,
      claim:,
      verdict: :needs_more_evidence,
      confidence_score: 0.2,
      checkability_status: :checkable
    )

    new_root = Article.create!(url: "https://b.com/nlow", normalized_url: "https://b.com/nlow", host: "b.com", fetch_status: :fetched)
    new_inv = Investigation.create!(submitted_url: new_root.url, normalized_url: new_root.normalized_url, root_article: new_root)
    ArticleClaim.create!(article: new_root, claim:, role: :body, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation: new_inv, claim:)

    # Should NOT reuse, should compute fresh (will be needs_more_evidence since no evidence)
    refute_includes result.reason_summary.to_s, "prior investigation"
  end

  test "assesses current explicit evidence instead of reusing a prior verdict" do
    claim = Claim.create!(canonical_text: "The agency published the 2025 report", canonical_fingerprint: "reuse_current_evidence", checkability_status: :checkable)
    prior_root = Article.create!(url: "https://prior.example/report", normalized_url: "https://prior.example/report", host: "prior.example", fetch_status: :fetched)
    prior_inv = Investigation.create!(submitted_url: prior_root.url, normalized_url: prior_root.normalized_url, root_article: prior_root)
    ClaimAssessment.create!(investigation: prior_inv, claim:, verdict: :supported, confidence_score: 0.91, checkability_status: :checkable, reason_summary: "Old evidence supported this.")

    root = Article.create!(url: "https://current.example/root", normalized_url: "https://current.example/root", host: "current.example", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    evidence = Article.create!(url: "https://agency.gov/correction", normalized_url: "https://agency.gov/correction", host: "agency.gov", fetch_status: :fetched, title: "Agency correction", body_text: "The agency did not publish the 2025 report.", authority_tier: :primary, authority_score: 0.95)
    entries = [ Analyzers::EvidencePacketBuilder::Entry.new(article: evidence, stance: :disputes, relevance_score: 0.95, authority_score: 0.95, authority_tier: "primary", source_kind: "government_record", source_role: "official_position", independence_group: "agency.gov", headline_divergence: 0.0) ]
    Llm::FakeClient.next_result = Llm::FakeClient::Result.new(verdict: "disputed", confidence_score: 0.93, reason_summary: "The new agency correction directly disputes publication.")

    result = Analyzers::ClaimAssessor.new(investigation:, claim:).call_with_llm_result(entries, nil)

    assert_equal :disputed, result.verdict
    assert_includes result.reason_summary, "new agency correction"
    refute_includes result.reason_summary, "prior investigation"
  end
end
