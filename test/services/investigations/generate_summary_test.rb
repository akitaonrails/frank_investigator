require "test_helper"

class Investigations::GenerateSummaryTest < ActiveSupport::TestCase
  setup do
    @root = Article.create!(
      url: "https://gensum.com/article", normalized_url: "https://gensum.com/article",
      host: "gensum.com", fetch_status: :fetched,
      body_text: "This article contains claims.", title: "Test Article"
    )
    @investigation = Investigation.create!(
      submitted_url: @root.url, normalized_url: @root.normalized_url,
      root_article: @root, status: :processing
    )
  end

  test "returns heuristic result with supported claims" do
    claim = Claim.create!(canonical_text: "GDP grew 3%", canonical_fingerprint: "gs_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation: @investigation, claim:, verdict: :supported, confidence_score: 0.8, checkability_status: :checkable)

    result = Investigations::GenerateSummary.call(investigation: @investigation)

    assert_kind_of Investigations::GenerateSummary::Result, result
    assert_includes %w[strong mixed weak insufficient], result.overall_quality
    assert result.conclusion.present?
    assert_kind_of Array, result.strengths
    assert_kind_of Array, result.weaknesses
  end

  test "returns heuristic result with disputed claims" do
    claim = Claim.create!(canonical_text: "Crime is up", canonical_fingerprint: "gs2_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation: @investigation, claim:, verdict: :disputed, confidence_score: 0.7, checkability_status: :checkable)

    result = Investigations::GenerateSummary.call(investigation: @investigation)

    assert_equal "weak", result.overall_quality
    assert result.weaknesses.any?
  end

  test "returns insufficient when no assessed claims" do
    result = Investigations::GenerateSummary.call(investigation: @investigation)

    assert_equal "insufficient", result.overall_quality
  end

  test "detects high headline bait as weakness" do
    @investigation.update!(headline_bait_score: 0.8)
    claim = Claim.create!(canonical_text: "Some claim", canonical_fingerprint: "gs3_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation: @investigation, claim:, verdict: :supported, confidence_score: 0.6, checkability_status: :checkable)

    result = Investigations::GenerateSummary.call(investigation: @investigation)

    assert result.weaknesses.any? { |w| w.include?("headline") || w.include?("sensational") || w.include?("manchete") }
  end

  test "quality values are constrained" do
    assert_equal %w[strong mixed weak insufficient], Investigations::GenerateSummary::QUALITY_VALUES
  end
end
