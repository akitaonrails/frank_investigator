require "test_helper"

class Analyzers::StalenessDetectorTest < ActiveSupport::TestCase
  setup do
    @investigation = Investigation.create!(
      submitted_url: "https://example.com/stale-test",
      normalized_url: "https://example.com/stale-test-#{SecureRandom.hex(4)}",
      status: :completed
    )
    @claim = Claim.create!(
      canonical_text: "Unemployment rate stood at 5% in Q1 2026 according to official government data",
      canonical_fingerprint: "stale_test_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      claim_timestamp_end: 1.month.ago.to_date,
      evidence_article_count: 2,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
    @assessment = ClaimAssessment.create!(
      investigation: @investigation,
      claim: @claim,
      verdict: :supported,
      confidence_score: 0.85,
      assessed_at: 2.days.ago
    )
  end

  test "not stale when recently assessed" do
    result = Analyzers::StalenessDetector.call(@assessment)
    refute result.stale
  end

  test "stale when recent claim assessed more than 7 days ago" do
    @assessment.update!(assessed_at: 8.days.ago)
    result = Analyzers::StalenessDetector.call(@assessment)

    assert result.stale
    assert_equal "time_elapsed", result.reason
    assert_equal :high, result.priority
  end

  test "historical claim stale after 30 days" do
    @claim.update!(claim_timestamp_end: 2.years.ago.to_date)
    @assessment.update!(assessed_at: 10.days.ago)

    result = Analyzers::StalenessDetector.call(@assessment)
    refute result.stale, "Historical claim should not be stale after only 10 days"

    @assessment.update!(assessed_at: 31.days.ago)
    result = Analyzers::StalenessDetector.call(@assessment)
    assert result.stale
    assert_equal :low, result.priority
  end

  test "stale when new evidence available" do
    # Start with evidence_article_count matching actual count (1)
    article1 = Article.create!(url: "https://example.com/ev1", normalized_url: "https://example.com/ev1-#{SecureRandom.hex(4)}", host: "example.com")
    ArticleClaim.create!(article: article1, claim: @claim, role: :body, surface_text: "Unemployment was 5% in Q1 2026 per official government stats and reports")
    @claim.update!(evidence_article_count: 1)

    # Now add a new article — count(2) > stored(1)
    article2 = Article.create!(url: "https://example.com/ev2", normalized_url: "https://example.com/ev2-#{SecureRandom.hex(4)}", host: "example.com")
    ArticleClaim.create!(article: article2, claim: @claim, role: :body, surface_text: "Official data confirmed the 5% unemployment rate in Q1 2026 quarterly report")

    result = Analyzers::StalenessDetector.call(@assessment)
    assert result.stale
    assert_equal "new_evidence", result.reason
    assert_equal :high, result.priority
  end

  test "low confidence needs_more_evidence stale after 3 days" do
    @assessment.update!(
      verdict: :needs_more_evidence,
      confidence_score: 0.35,
      assessed_at: 4.days.ago
    )

    result = Analyzers::StalenessDetector.call(@assessment)
    assert result.stale
    assert_equal "low_confidence", result.reason
    assert_equal :medium, result.priority
  end

  test "pending assessments are never stale" do
    @assessment.update!(verdict: :pending, assessed_at: 60.days.ago)
    result = Analyzers::StalenessDetector.call(@assessment)
    refute result.stale
  end
end
