require "test_helper"

class Claims::ReassessStaleClaimsJobTest < ActiveSupport::TestCase
  setup do
    @root = Article.create!(url: "https://ex.com/reassess", normalized_url: "https://ex.com/reassess", host: "ex.com", fetch_status: :fetched)
    @investigation = Investigation.create!(submitted_url: @root.url, normalized_url: @root.normalized_url, root_article: @root)
    @claim = Claim.create!(canonical_text: "Stale claim test", canonical_fingerprint: "stale_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    @assessment = ClaimAssessment.create!(
      investigation: @investigation, claim: @claim,
      verdict: :supported, confidence_score: 0.7,
      stale_at: 1.hour.ago, staleness_reason: "new_evidence",
      checkability_status: :checkable
    )
  end

  test "reassesses stale claims and clears staleness" do
    Claims::ReassessStaleClaimsJob.perform_now

    @assessment.reload
    assert_nil @assessment.stale_at
    assert_nil @assessment.staleness_reason
    assert @assessment.assessed_at.present?
    assert_equal 1, @assessment.reassessment_count
  end

  test "skips non-stale assessments" do
    @assessment.update!(stale_at: nil)
    original_count = @assessment.reassessment_count

    Claims::ReassessStaleClaimsJob.perform_now

    @assessment.reload
    assert_equal original_count, @assessment.reassessment_count
  end

  test "limits reassessments per run" do
    # Create more stale assessments than the limit
    25.times do |i|
      claim = Claim.create!(canonical_text: "Bulk #{i}", canonical_fingerprint: "bulk_#{SecureRandom.hex(4)}", checkability_status: :checkable)
      ClaimAssessment.create!(
        investigation: @investigation, claim:,
        verdict: :supported, confidence_score: 0.5,
        stale_at: i.minutes.ago, staleness_reason: "new_evidence",
        checkability_status: :checkable
      )
    end

    Claims::ReassessStaleClaimsJob.perform_now

    # Should only process MAX_REASSESSMENTS_PER_RUN (20)
    remaining_stale = ClaimAssessment.where.not(stale_at: nil).count
    assert remaining_stale >= 5, "Expected at least 5 remaining stale (limit is 20 + original 1 = 21 reassessed from 26)"
  end

  test "creates verdict snapshot on reassessment" do
    Claims::ReassessStaleClaimsJob.perform_now

    @assessment.reload
    assert @assessment.verdict_snapshots.any?, "Expected at least one verdict snapshot"
  end
end
