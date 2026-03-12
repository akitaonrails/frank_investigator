require "test_helper"

class Analyzers::SourceCorrectionDetectorTest < ActiveSupport::TestCase
  test "detects body changes and flags affected assessments" do
    article = Article.create!(
      url: "https://scd.com/art", normalized_url: "https://scd.com/art",
      host: "scd.com", fetch_status: :fetched, body_text: "Original body text for detection",
      body_fingerprint: "wrong_hash_to_trigger_detection",
      body_changed_since_assessment: false
    )

    claim = Claim.create!(canonical_text: "SCD claim", canonical_fingerprint: "scd_#{SecureRandom.hex(4)}")
    root = Article.create!(url: "https://scd.com/root", normalized_url: "https://scd.com/root", host: "scd.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    assessment = ClaimAssessment.create!(
      investigation:, claim:, verdict: :supported,
      confidence_score: 0.8, checkability_status: :checkable
    )
    EvidenceItem.create!(
      claim_assessment: assessment,
      source_url: article.normalized_url,
      article:
    )

    result = Analyzers::SourceCorrectionDetector.call

    assert_equal 1, result.corrected_articles
    assert_equal 1, result.affected_assessments

    article.reload
    assert article.body_changed_since_assessment

    assessment.reload
    assert assessment.stale_at.present?
    assert_equal "source_corrected", assessment.staleness_reason
  end

  test "skips articles with matching fingerprint" do
    body = "Unchanged body text"
    fingerprint = Analyzers::TextAnalysis.stable_content_fingerprint(body)
    Article.create!(
      url: "https://scd2.com/ok", normalized_url: "https://scd2.com/ok",
      host: "scd2.com", fetch_status: :fetched, body_text: body,
      body_fingerprint: fingerprint,
      body_changed_since_assessment: false
    )

    result = Analyzers::SourceCorrectionDetector.call
    assert_equal 0, result.corrected_articles
  end

  test "skips already flagged articles" do
    Article.create!(
      url: "https://scd3.com/flagged", normalized_url: "https://scd3.com/flagged",
      host: "scd3.com", fetch_status: :fetched, body_text: "Changed text",
      body_fingerprint: "old_hash",
      body_changed_since_assessment: true
    )

    result = Analyzers::SourceCorrectionDetector.call
    assert_equal 0, result.corrected_articles
  end

  test "does not flag already stale assessments" do
    article = Article.create!(
      url: "https://scd4.com/art", normalized_url: "https://scd4.com/art",
      host: "scd4.com", fetch_status: :fetched, body_text: "Body text changed",
      body_fingerprint: "old_hash_for_stale",
      body_changed_since_assessment: false
    )

    claim = Claim.create!(canonical_text: "Already stale claim", canonical_fingerprint: "scd4_#{SecureRandom.hex(4)}")
    root = Article.create!(url: "https://scd4.com/root", normalized_url: "https://scd4.com/root", host: "scd4.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    assessment = ClaimAssessment.create!(
      investigation:, claim:, verdict: :supported,
      confidence_score: 0.8, checkability_status: :checkable,
      stale_at: 1.day.ago, staleness_reason: "new_evidence"
    )
    EvidenceItem.create!(claim_assessment: assessment, source_url: article.normalized_url, article:)

    result = Analyzers::SourceCorrectionDetector.call

    assert_equal 1, result.corrected_articles
    assert_equal 0, result.affected_assessments # already stale, not re-flagged
  end

  test "returns zeros when no articles have fingerprints" do
    result = Analyzers::SourceCorrectionDetector.call
    assert_equal 0, result.corrected_articles
    assert_equal 0, result.affected_assessments
  end
end
