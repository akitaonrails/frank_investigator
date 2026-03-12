require "test_helper"

class TruthOverConsensusTest < ActiveSupport::TestCase
  EvidenceEntry = Struct.new(:stance, :relevance_score, :authority_score, :authority_tier,
                             :source_kind, :independence_group, :article, keyword_init: true)
  FakeArticle = Struct.new(:normalized_url, :title, :excerpt, :body_text, :host,
                           :fetched_at, :published_at, keyword_init: true)

  setup do
    @investigation = Investigation.create!(
      submitted_url: "https://example.com/truth-test",
      normalized_url: "https://example.com/truth-test-#{SecureRandom.hex(4)}",
      status: :processing
    )
    @claim = Claim.create!(
      canonical_text: "The unemployment rate in Q4 2025 was 3.7%",
      canonical_fingerprint: "truth_test_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
  end

  test "secondary weight cap prevents volume from dominating" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    # 10 secondary sources supporting at max relevance/authority
    secondary_entries = 10.times.map do |i|
      EvidenceEntry.new(
        stance: :supports, relevance_score: 0.9, authority_score: 0.7,
        authority_tier: "secondary", source_kind: "news", independence_group: "group_#{i}",
        article: FakeArticle.new(fetched_at: Time.current)
      )
    end

    weight = assessor.send(:weight_for, secondary_entries, :supports)
    # Without cap, 10 * 0.9 * 0.7 = 6.3. With cap, should be 0.8
    assert_equal 0.8, weight
  end

  test "primary source veto blocks supported when primary disputes" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    entries = [
      # 1 primary source disputes
      EvidenceEntry.new(stance: :disputes, authority_tier: "primary", relevance_score: 0.95, authority_score: 0.97),
      # 5 secondary sources support
      *5.times.map do
        EvidenceEntry.new(stance: :supports, authority_tier: "secondary", relevance_score: 0.8, authority_score: 0.6)
      end
    ]

    verdict, confidence = assessor.send(:apply_primary_veto, :supported, 0.85, entries)
    assert_equal :mixed, verdict
    assert_operator confidence, :<=, 0.60
  end

  test "no veto when only primary supports and secondary disputes" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    entries = [
      EvidenceEntry.new(stance: :supports, authority_tier: "primary", relevance_score: 0.95, authority_score: 0.97),
      EvidenceEntry.new(stance: :disputes, authority_tier: "secondary", relevance_score: 0.8, authority_score: 0.5)
    ]

    verdict, confidence = assessor.send(:apply_primary_veto, :supported, 0.85, entries)
    # No veto — primary supports, only secondary disputes. Primary authority holds.
    assert_equal :supported, verdict
    assert_equal 0.85, confidence
  end

  test "opposing primary sources force mixed with low confidence" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    entries = [
      EvidenceEntry.new(stance: :supports, authority_tier: "primary", relevance_score: 0.9, authority_score: 0.95),
      EvidenceEntry.new(stance: :disputes, authority_tier: "primary", relevance_score: 0.9, authority_score: 0.93)
    ]

    verdict, confidence = assessor.send(:apply_primary_veto, :supported, 0.90, entries)
    assert_equal :mixed, verdict
    assert_operator confidence, :<=, 0.50
  end

  test "primary veto does not affect disputed verdicts" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    entries = [
      EvidenceEntry.new(stance: :disputes, authority_tier: "primary", relevance_score: 0.95, authority_score: 0.97)
    ]

    verdict, confidence = assessor.send(:apply_primary_veto, :disputed, 0.85, entries)
    assert_equal :disputed, verdict
    assert_equal 0.85, confidence
  end
end

class WeightedLlmVotingTest < ActiveSupport::TestCase
  test "confidence-weighted voting prefers high-confidence minority" do
    client = Llm::RubyLlmClient.new(models: [])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "disputed", confidence_score: 0.95, reason_summary: "Primary data contradicts"),
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.40, reason_summary: "Some articles say so"),
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.35, reason_summary: "Others agree")
    ]

    # By count: supported wins (2 vs 1). By confidence weight: disputed wins (0.95 vs 0.75).
    aggregated = client.send(:aggregate_results, results)
    assert_equal "disputed", aggregated.verdict
  end

  test "unanimous high-confidence results are not penalized" do
    client = Llm::RubyLlmClient.new(models: [])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.90, reason_summary: "Clear evidence"),
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.88, reason_summary: "Confirmed")
    ]

    aggregated = client.send(:aggregate_results, results)
    assert_equal "supported", aggregated.verdict
    assert aggregated.unanimous
    assert_in_delta 0.89, aggregated.confidence_score, 0.01
  end
end
