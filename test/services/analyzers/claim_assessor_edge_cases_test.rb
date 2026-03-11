require "test_helper"

class Analyzers::ClaimAssessorEdgeCasesTest < ActiveSupport::TestCase
  setup do
    @previous_llm = Rails.application.config.x.frank_investigator.llm_client_class
    Rails.application.config.x.frank_investigator.llm_client_class = "Llm::FakeClient"
    Llm::FakeClient.next_result = nil
  end

  teardown do
    Rails.application.config.x.frank_investigator.llm_client_class = @previous_llm
    Llm::FakeClient.next_result = nil
  end

  test "returns not_checkable for opinion claims" do
    root = Article.create!(url: "https://a.com/nc", normalized_url: "https://a.com/nc", host: "a.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(canonical_text: "I think this is terrible", canonical_fingerprint: "nc_opinion", checkability_status: :not_checkable)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)

    assert_equal :not_checkable, result.verdict
    assert_equal 0.9, result.confidence_score
    assert_equal :not_checkable, result.checkability_status
    assert_equal 0, result.authority_score
  end

  test "returns needs_more_evidence when no evidence exists" do
    root = Article.create!(url: "https://a.com/ne", normalized_url: "https://a.com/ne", host: "a.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(canonical_text: "Aliens exist on Mars confirmed", canonical_fingerprint: "ne_noev", checkability_status: :checkable)
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)

    assert_equal :needs_more_evidence, result.verdict
    assert_operator result.confidence_score, :>=, 0
    assert_includes result.missing_evidence_summary, "Need"
  end

  test "confidence is clamped to 0.97" do
    root = Article.create!(url: "https://a.com/clamp", normalized_url: "https://a.com/clamp", host: "a.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    claim = Claim.create!(canonical_text: "Budget confirmed by Congress", canonical_fingerprint: "clamp_test", checkability_status: :checkable)
    ArticleClaim.create!(article: root, claim:, role: :body, surface_text: claim.canonical_text)

    # Create multiple strong evidence sources
    5.times do |i|
      ev = Article.create!(
        url: "https://gov#{i}.example.com/doc", normalized_url: "https://gov#{i}.example.com/doc",
        host: "gov#{i}.example.com", title: "Budget confirmed by Congress official record #{i}",
        body_text: "Budget confirmed by Congress in the official record submitted this week.",
        excerpt: "Budget confirmed", fetch_status: :fetched, fetched_at: Time.current,
        source_kind: :government_record, authority_tier: :primary, authority_score: 0.98,
        independence_group: "gov#{i}.example.com"
      )
      ArticleClaim.create!(article: ev, claim:, role: :supporting, surface_text: claim.canonical_text)
    end

    result = Analyzers::ClaimAssessor.call(investigation:, claim:)
    assert_operator result.confidence_score, :<=, 0.97
  end
end
