require "test_helper"

class ClaimAssessmentTest < ActiveSupport::TestCase
  setup do
    @root = Article.create!(url: "https://ex.com/ca", normalized_url: "https://ex.com/ca", host: "ex.com", fetch_status: :fetched)
    @investigation = Investigation.create!(submitted_url: @root.url, normalized_url: @root.normalized_url, root_article: @root)
    @claim = Claim.create!(canonical_text: "Assessment test", canonical_fingerprint: "ca_#{SecureRandom.hex(4)}")
    @assessment = ClaimAssessment.create!(investigation: @investigation, claim: @claim)
  end

  test "record_verdict_change creates initial snapshot" do
    @assessment.record_verdict_change!(
      new_verdict: :supported,
      new_confidence: 0.8,
      new_reason: "Strong evidence",
      trigger: "initial_assessment"
    )

    assert_equal 1, @assessment.verdict_snapshots.count
    snapshot = @assessment.verdict_snapshots.first
    assert_equal "supported", snapshot.verdict
    assert_nil snapshot.previous_verdict
    assert_equal 0.8, snapshot.confidence_score
    assert_nil snapshot.previous_confidence_score
    assert_equal "initial_assessment", snapshot.trigger
  end

  test "record_verdict_change creates snapshot on verdict change" do
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.8,
      new_reason: "First", trigger: "initial_assessment"
    )
    @assessment.record_verdict_change!(
      new_verdict: :disputed, new_confidence: 0.7,
      new_reason: "Revised", trigger: "reassessment"
    )

    assert_equal 2, @assessment.verdict_snapshots.count
    latest = @assessment.verdict_snapshots.order(:created_at).last
    assert_equal "disputed", latest.verdict
    assert_equal "supported", latest.previous_verdict
    assert_equal 0.7, latest.confidence_score
    assert_in_delta 0.8, latest.previous_confidence_score, 0.01
  end

  test "record_verdict_change creates snapshot on significant confidence shift" do
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.8,
      new_reason: "First", trigger: "initial_assessment"
    )
    # Same verdict but confidence drops significantly
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.5,
      new_reason: "Less confident", trigger: "reassessment"
    )

    assert_equal 2, @assessment.verdict_snapshots.count
  end

  test "record_verdict_change skips snapshot when change is minor" do
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.8,
      new_reason: "First", trigger: "initial_assessment"
    )
    # Same verdict, minor confidence change (< CONFIDENCE_CHANGE_THRESHOLD)
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.82,
      new_reason: "Slightly more confident", trigger: "reassessment"
    )

    assert_equal 1, @assessment.verdict_snapshots.count
    # But verdict/confidence should still update
    @assessment.reload
    assert_in_delta 0.82, @assessment.confidence_score, 0.01
  end

  test "verdict_changed_count tracks actual verdict changes" do
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.8,
      new_reason: "A", trigger: "initial_assessment"
    )
    @assessment.record_verdict_change!(
      new_verdict: :disputed, new_confidence: 0.7,
      new_reason: "B", trigger: "reassessment"
    )
    @assessment.record_verdict_change!(
      new_verdict: :supported, new_confidence: 0.75,
      new_reason: "C", trigger: "reassessment"
    )

    assert @assessment.verdict_changed_count >= 2
  end

  test "build_evidence_content_hashes fingerprints evidence articles" do
    evidence_article = Article.create!(
      url: "https://ev.com/hash", normalized_url: "https://ev.com/hash",
      host: "ev.com", fetch_status: :fetched, body_text: "This is the evidence body text for hashing."
    )
    EvidenceItem.create!(
      claim_assessment: @assessment,
      source_url: evidence_article.normalized_url,
      article: evidence_article
    )

    hashes = @assessment.send(:build_evidence_content_hashes)

    assert_equal 1, hashes.size
    assert hashes[evidence_article.normalized_url].present?
    assert_equal 64, hashes[evidence_article.normalized_url].length # SHA-256 hex
  end

  test "build_evidence_snapshot captures evidence state" do
    evidence_article = Article.create!(
      url: "https://ev.com/snap", normalized_url: "https://ev.com/snap",
      host: "ev.com", fetch_status: :fetched, title: "Evidence Title",
      authority_score: 0.85
    )
    EvidenceItem.create!(
      claim_assessment: @assessment,
      source_url: evidence_article.normalized_url,
      article: evidence_article,
      stance: :supports,
      authority_score: 0.85
    )

    snapshot = @assessment.send(:build_evidence_snapshot)

    assert_equal 1, snapshot.size
    assert_equal "Evidence Title", snapshot.first[:title]
    assert_equal "supports", snapshot.first[:stance]
  end
end
