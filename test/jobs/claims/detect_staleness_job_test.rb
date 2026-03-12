require "test_helper"

class Claims::DetectStalenessJobTest < ActiveSupport::TestCase
  setup do
    @investigation = Investigation.create!(
      submitted_url: "https://example.com/detect-stale",
      normalized_url: "https://example.com/detect-stale-#{SecureRandom.hex(4)}",
      status: :completed
    )
    @claim = Claim.create!(
      canonical_text: "GDP growth was 2.5% in 2025 per the Central Bank official quarterly report",
      canonical_fingerprint: "detect_stale_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      claim_timestamp_end: 1.month.ago.to_date,
      evidence_article_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
  end

  test "flags stale assessments" do
    assessment = ClaimAssessment.create!(
      investigation: @investigation,
      claim: @claim,
      verdict: :supported,
      confidence_score: 0.8,
      assessed_at: 10.days.ago
    )

    Claims::DetectStalenessJob.perform_now

    assessment.reload
    assert assessment.stale_at.present?
    assert_equal "time_elapsed", assessment.staleness_reason
  end

  test "does not flag fresh assessments" do
    assessment = ClaimAssessment.create!(
      investigation: @investigation,
      claim: @claim,
      verdict: :supported,
      confidence_score: 0.8,
      assessed_at: 1.day.ago
    )

    Claims::DetectStalenessJob.perform_now

    assessment.reload
    assert_nil assessment.stale_at
  end

  test "does not flag already stale assessments" do
    assessment = ClaimAssessment.create!(
      investigation: @investigation,
      claim: @claim,
      verdict: :supported,
      confidence_score: 0.8,
      assessed_at: 10.days.ago,
      stale_at: 1.day.ago,
      staleness_reason: "time_elapsed"
    )

    Claims::DetectStalenessJob.perform_now

    assessment.reload
    # stale_at should remain as originally set
    assert assessment.stale_at <= 1.day.ago
  end
end
