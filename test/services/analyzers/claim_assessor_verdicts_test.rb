require "test_helper"
require "ostruct"

class Analyzers::ClaimAssessorVerdictsTest < ActiveSupport::TestCase
  setup do
    @root = Article.create!(url: "https://ex.com/verdicts", normalized_url: "https://ex.com/verdicts", host: "ex.com", fetch_status: :fetched)
    @investigation = Investigation.create!(submitted_url: @root.url, normalized_url: @root.normalized_url, root_article: @root)
    @claim = Claim.create!(canonical_text: "GDP grew 3% in 2025", canonical_fingerprint: "verdict_test_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation: @investigation, claim: @claim)
  end

  test "returns not_checkable result for not_checkable claims" do
    @claim.update!(checkability_status: :not_checkable)
    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    assert_equal :not_checkable, result.verdict
    assert_equal 0.9, result.confidence_score
    assert_equal :not_checkable, result.checkability_status
  end

  test "returns needs_more_evidence when no evidence exists" do
    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    assert_equal :needs_more_evidence, result.verdict
    assert result.confidence_score < 0.5
    assert_equal :checkable, result.checkability_status
  end

  test "returns supported when strong supporting evidence exists" do
    3.times do |i|
      art = Article.create!(
        url: "https://source#{i}.com/s", normalized_url: "https://source#{i}.com/s",
        host: "source#{i}.com", fetch_status: :fetched, fetched_at: 1.day.ago,
        authority_tier: :primary, authority_score: 0.95, source_kind: :government_record,
        body_text: "Body text confirming GDP grew 3%", title: "GDP Report #{i}"
      )
      ArticleClaim.create!(article: art, claim: @claim, stance: :supports, importance_score: 0.9, surface_text: @claim.canonical_text)
    end

    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    assert_equal :supported, result.verdict
    assert result.confidence_score > 0.5
  end

  test "returns disputed when strong disputing evidence exists" do
    3.times do |i|
      art = Article.create!(
        url: "https://dispute#{i}.com/d", normalized_url: "https://dispute#{i}.com/d",
        host: "dispute#{i}.com", fetch_status: :fetched, fetched_at: 1.day.ago,
        authority_tier: :primary, authority_score: 0.95, source_kind: :government_record,
        body_text: "GDP actually fell 1%", title: "Correction #{i}"
      )
      ArticleClaim.create!(article: art, claim: @claim, stance: :disputes, importance_score: 0.9, surface_text: @claim.canonical_text)
    end

    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    assert_equal :disputed, result.verdict
    assert result.confidence_score > 0.5
  end

  test "returns mixed when both support and dispute are strong" do
    # Supporting articles: body text overlaps with claim tokens
    3.times do |j|
      art = Article.create!(
        url: "https://mixedsup#{j}.com/m", normalized_url: "https://mixedsup#{j}.com/m",
        host: "mixedsup#{j}.com", fetch_status: :fetched, fetched_at: 1.day.ago,
        authority_tier: :primary, authority_score: 0.95, source_kind: :government_record,
        body_text: "Official data confirms GDP grew 3% in 2025 according to government statistics.",
        title: "GDP Report Support #{j}"
      )
      ArticleClaim.create!(article: art, claim: @claim, stance: :supports, importance_score: 0.9, surface_text: @claim.canonical_text)
    end
    # Disputing articles: body text overlaps AND has negation patterns
    3.times do |j|
      art = Article.create!(
        url: "https://mixeddis#{j}.com/m", normalized_url: "https://mixeddis#{j}.com/m",
        host: "mixeddis#{j}.com", fetch_status: :fetched, fetched_at: 1.day.ago,
        authority_tier: :primary, authority_score: 0.95, source_kind: :government_record,
        body_text: "It is false that GDP grew 3% in 2025. The claim is incorrect and misleading.",
        title: "GDP Correction #{j}"
      )
      ArticleClaim.create!(article: art, claim: @claim, stance: :disputes, importance_score: 0.9, surface_text: @claim.canonical_text)
    end

    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    assert_equal :mixed, result.verdict
  end

  test "apply_primary_veto forces supported to mixed when primary disputes" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    # Build entries directly to isolate the veto logic
    supporting_art = Article.create!(
      url: "https://sec.com/veto", normalized_url: "https://sec.com/veto",
      host: "sec.com", fetch_status: :fetched, authority_tier: :secondary
    )
    disputing_art = Article.create!(
      url: "https://gov.com/veto", normalized_url: "https://gov.com/veto",
      host: "gov.com", fetch_status: :fetched, authority_tier: :primary
    )
    entries = [
      Analyzers::EvidencePacketBuilder::Entry.new(
        article: supporting_art, stance: :supports, relevance_score: 0.9,
        authority_score: 0.7, authority_tier: "secondary", source_kind: "news_article",
        independence_group: "sec.com", headline_divergence: 0.0
      ),
      Analyzers::EvidencePacketBuilder::Entry.new(
        article: disputing_art, stance: :disputes, relevance_score: 0.3,
        authority_score: 0.98, authority_tier: "primary", source_kind: "government_record",
        independence_group: "gov.com", headline_divergence: 0.0
      )
    ]

    verdict, confidence = assessor.send(:apply_primary_veto, :supported, 0.75, entries)
    assert_equal :mixed, verdict
    assert confidence <= 0.60
  end

  test "apply_primary_veto does not veto when primary supports too" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    art1 = Article.create!(url: "https://a.com/noveto", normalized_url: "https://a.com/noveto", host: "a.com", fetch_status: :fetched, authority_tier: :primary)
    art2 = Article.create!(url: "https://b.com/noveto", normalized_url: "https://b.com/noveto", host: "b.com", fetch_status: :fetched, authority_tier: :primary)
    entries = [
      Analyzers::EvidencePacketBuilder::Entry.new(
        article: art1, stance: :supports, relevance_score: 0.9,
        authority_score: 0.95, authority_tier: "primary", source_kind: "government_record",
        independence_group: "a.com", headline_divergence: 0.0
      ),
      Analyzers::EvidencePacketBuilder::Entry.new(
        article: art2, stance: :disputes, relevance_score: 0.8,
        authority_score: 0.95, authority_tier: "primary", source_kind: "government_record",
        independence_group: "b.com", headline_divergence: 0.0
      )
    ]

    # Opposing primaries → mixed with harder cap
    verdict, confidence = assessor.send(:apply_primary_veto, :supported, 0.75, entries)
    assert_equal :mixed, verdict
    assert confidence <= 0.50
  end

  test "unsubstantiated viral flags when 3+ secondaries support with no primary" do
    4.times do |i|
      art = Article.create!(
        url: "https://blog#{i}.com/viral", normalized_url: "https://blog#{i}.com/viral",
        host: "blog#{i}.com", fetch_status: :fetched, fetched_at: 1.day.ago,
        authority_tier: :secondary, authority_score: 0.55, source_kind: :news_article,
        body_text: "Sources say GDP grew 3% in 2025 according to reports circulating online.",
        title: "GDP grew 3% in 2025 - Blog #{i}"
      )
      ArticleClaim.create!(article: art, claim: @claim, stance: :supports, importance_score: 0.8, surface_text: @claim.canonical_text)
    end

    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    assert result.unsubstantiated_viral, "Expected unsubstantiated_viral to be true"
    assert result.confidence_score <= 0.45
  end

  test "confidence capped when single independence cluster" do
    # All from same host = 1 independence group
    2.times do |i|
      art = Article.create!(
        url: "https://same.com/art#{i}", normalized_url: "https://same.com/art#{i}",
        host: "same.com", fetch_status: :fetched, fetched_at: 1.day.ago,
        authority_tier: :secondary, authority_score: 0.7, source_kind: :news_article,
        body_text: "Same source evidence", title: "Article #{i}", independence_group: "same.com"
      )
      ArticleClaim.create!(article: art, claim: @claim, stance: :supports, importance_score: 0.9, surface_text: @claim.canonical_text)
    end

    result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: @claim)

    # Single cluster should cap confidence
    assert result.confidence_score <= 0.65
  end

  test "merge_with_llm boosts confidence when LLM agrees" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)
    merged_verdict, merged_confidence = assessor.send(
      :merge_with_llm,
      heuristic_verdict: :supported,
      heuristic_confidence: 0.7,
      llm_result: Llm::FakeClient::Result.new(verdict: "supported", confidence_score: 0.8, reason_summary: "Agrees")
    )

    assert_equal :supported, merged_verdict
    assert_equal 0.75, merged_confidence
  end

  test "merge_with_llm returns mixed when LLM disagrees" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)
    merged_verdict, merged_confidence = assessor.send(
      :merge_with_llm,
      heuristic_verdict: :supported,
      heuristic_confidence: 0.7,
      llm_result: Llm::FakeClient::Result.new(verdict: "disputed", confidence_score: 0.8, reason_summary: "Disagrees")
    )

    assert_equal :mixed, merged_verdict
    assert merged_confidence < 0.7
  end

  test "merge_with_llm defers to LLM when heuristic is needs_more_evidence and LLM is confident" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)
    merged_verdict, merged_confidence = assessor.send(
      :merge_with_llm,
      heuristic_verdict: :needs_more_evidence,
      heuristic_confidence: 0.3,
      llm_result: Llm::FakeClient::Result.new(verdict: "supported", confidence_score: 0.85, reason_summary: "Strong evidence")
    )

    assert_equal :supported, merged_verdict
    assert_equal 0.85, merged_confidence
  end

  test "build_reason_summary generates heuristic summary when no LLM" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)
    art = Article.create!(
      url: "https://src.com/reason", normalized_url: "https://src.com/reason",
      host: "src.com", fetch_status: :fetched, authority_tier: :primary,
      authority_score: 0.9, source_kind: :government_record,
      body_text: "Evidence", title: "Source Doc"
    )
    entry = OpenStruct.new(
      article: art, stance: :supports, importance_score: 0.8,
      authority_score: 0.9, authority_tier: "primary",
      source_kind: "government_record", independence_group: "src.com",
      headline_divergence: 0.1
    )

    summary = assessor.send(:build_reason_summary, [ entry ], :supported, { weighted_support: 0.72, weighted_dispute: 0.0 }, nil)

    assert_includes summary, "Verdict: supported"
    assert_includes summary, "Primary sources:"
    assert_includes summary, "1 source(s) support"
  end

  test "build_missing_evidence identifies gaps" do
    assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: @claim)

    summary = assessor.send(:build_missing_evidence, [], 0.0)
    assert_includes summary, "Need at least one"

    art = Article.create!(
      url: "https://src.com/gap", normalized_url: "https://src.com/gap",
      host: "src.com", fetch_status: :fetched, authority_tier: :secondary,
      authority_score: 0.6, body_text: "Text", title: "Source"
    )
    entry = OpenStruct.new(
      article: art, stance: :supports, authority_tier: "secondary",
      independence_group: "src.com", headline_divergence: 0.0
    )

    summary = assessor.send(:build_missing_evidence, [ entry ], 0.5)
    assert_includes summary, "primary authoritative sources"
    assert_includes summary, "independent source groups"
  end
end
