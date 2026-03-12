require "test_helper"

class UnicodeNormalizationTest < ActiveSupport::TestCase
  test "NFKC normalizes fullwidth characters" do
    # Fullwidth "５%" should become "5%"
    normalized = Analyzers::TextAnalysis.normalize("GDP grew ５.１%")
    assert_includes normalized, "5 1"
  end

  test "replaces Cyrillic confusables with Latin equivalents" do
    # Cyrillic а, е, о look identical to Latin a, e, o
    cyrillic_text = "\u0430\u0435\u043E"  # Cyrillic а, е, о
    normalized = Analyzers::TextAnalysis.unicode_normalize(cyrillic_text)
    assert_equal "aeo", normalized
  end

  test "strips zero-width characters" do
    text = "claim\u200B\u200Ctext\u200D"
    normalized = Analyzers::TextAnalysis.unicode_normalize(text)
    assert_equal "claimtext", normalized
  end

  test "normalizes smart quotes and dashes" do
    text = "\u201Cclaim\u201D \u2014 test"
    normalized = Analyzers::TextAnalysis.unicode_normalize(text)
    assert_includes normalized, '"claim"'
    assert_includes normalized, "-"
  end

  test "fingerprint is consistent despite homoglyph attacks" do
    latin = "Brazil GDP rose 3%"
    # Same text but with Cyrillic а, о instead of Latin a, o
    homoglyph = "Br\u0430zil GDP r\u043Ese 3%"

    fp_latin = Analyzers::ClaimFingerprint.call(latin)
    fp_homoglyph = Analyzers::ClaimFingerprint.call(homoglyph)

    assert_equal fp_latin, fp_homoglyph
  end
end

class EvidenceProvenanceTest < ActiveSupport::TestCase
  setup do
    @investigation = Investigation.create!(
      submitted_url: "https://example.com/prov-test",
      normalized_url: "https://example.com/prov-test-#{SecureRandom.hex(4)}",
      status: :processing
    )
    claim = Claim.create!(
      canonical_text: "Test claim for provenance tracking",
      canonical_fingerprint: "prov_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
    @assessment = ClaimAssessment.create!(
      investigation: @investigation,
      claim: claim,
      verdict: :pending,
      confidence_score: 0
    )
  end

  test "verdict snapshot captures evidence content hashes" do
    article = Article.create!(
      url: "https://source.com/data", normalized_url: "https://source.com/data-#{SecureRandom.hex(4)}",
      host: "source.com", title: "Source Data",
      body_text: "The unemployment rate is 3.7% according to BLS data."
    )
    EvidenceItem.create!(
      claim_assessment: @assessment, source_url: article.normalized_url, article: article,
      stance: "supports", authority_score: 0.9, relevance_score: 0.8
    )

    @assessment.record_verdict_change!(
      new_verdict: :supported,
      new_confidence: 0.85,
      new_reason: "BLS data confirms",
      trigger: "initial_assessment"
    )

    snapshot = @assessment.verdict_snapshots.first
    assert snapshot.evidence_content_hashes.present?
    assert_equal Digest::SHA256.hexdigest(article.body_text), snapshot.evidence_content_hashes[article.normalized_url]
  end
end

class SourceCorrectionDetectorTest < ActiveSupport::TestCase
  test "detects when article body changes" do
    article = Article.create!(
      url: "https://news.com/story", normalized_url: "https://news.com/story-#{SecureRandom.hex(4)}",
      host: "news.com", title: "Original story", fetch_status: :fetched,
      body_text: "Original content here",
      body_fingerprint: Digest::SHA256.hexdigest("Original content here")
    )

    # Simulate body change (e.g., correction published)
    article.update_column(:body_text, "CORRECTION: Updated content here with retraction")

    result = Analyzers::SourceCorrectionDetector.call

    assert_operator result.corrected_articles, :>=, 1
    article.reload
    assert article.body_changed_since_assessment
  end

  test "flags assessments using corrected articles as stale" do
    investigation = Investigation.create!(
      submitted_url: "https://example.com/corr-test",
      normalized_url: "https://example.com/corr-test-#{SecureRandom.hex(4)}",
      status: :processing
    )
    article = Article.create!(
      url: "https://news.com/corrected", normalized_url: "https://news.com/corrected-#{SecureRandom.hex(4)}",
      host: "news.com", title: "Story to be corrected", fetch_status: :fetched,
      body_text: "Original content",
      body_fingerprint: Digest::SHA256.hexdigest("Original content")
    )
    claim = Claim.create!(
      canonical_text: "Test claim for correction detection",
      canonical_fingerprint: "corr_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
    assessment = ClaimAssessment.create!(
      investigation: investigation, claim: claim,
      verdict: :supported, confidence_score: 0.85
    )
    EvidenceItem.create!(
      claim_assessment: assessment, source_url: article.normalized_url,
      article: article, stance: "supports", authority_score: 0.8, relevance_score: 0.7
    )

    # Simulate correction
    article.update_column(:body_text, "CORRECTION: This article has been updated")

    result = Analyzers::SourceCorrectionDetector.call

    assessment.reload
    assert assessment.stale_at.present?
    assert_equal "source_corrected", assessment.staleness_reason
  end

  test "does not flag unchanged articles" do
    article = Article.create!(
      url: "https://stable.com/data", normalized_url: "https://stable.com/data-#{SecureRandom.hex(4)}",
      host: "stable.com", title: "Stable article", fetch_status: :fetched,
      body_text: "Unchanged content",
      body_fingerprint: Digest::SHA256.hexdigest("Unchanged content")
    )

    result = Analyzers::SourceCorrectionDetector.call
    article.reload
    refute article.body_changed_since_assessment
  end
end

class ClaimVariantTrackingTest < ActiveSupport::TestCase
  test "variant claim links to canonical parent" do
    parent = Claim.create!(
      canonical_text: "Brazil GDP grew 3.1% in Q1 2025",
      canonical_fingerprint: "parent_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    variant = Claim.create!(
      canonical_text: "Brazil GDP grew nearly 3% in early 2025",
      canonical_fingerprint: "variant_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      canonical_parent: parent,
      variant_of_fingerprint: parent.canonical_fingerprint,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    assert_equal parent, variant.canonical_parent
    assert_includes parent.variants, variant
  end

  test "prior_variant_assessment returns parent assessment" do
    parent = Claim.create!(
      canonical_text: "Inflation fell to 2.1%",
      canonical_fingerprint: "pva_parent_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
    investigation = Investigation.create!(
      submitted_url: "https://example.com/pva",
      normalized_url: "https://example.com/pva-#{SecureRandom.hex(4)}",
      status: :processing
    )
    parent_assessment = ClaimAssessment.create!(
      investigation: investigation, claim: parent,
      verdict: :supported, confidence_score: 0.85
    )

    variant = Claim.create!(
      canonical_text: "Inflation dropped to around 2% last quarter",
      canonical_fingerprint: "pva_variant_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      canonical_parent: parent,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    prior = variant.prior_variant_assessment
    assert_equal parent_assessment, prior
  end

  test "prior_variant_assessment returns nil without parent" do
    claim = Claim.create!(
      canonical_text: "Standalone claim",
      canonical_fingerprint: "standalone_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )

    assert_nil claim.prior_variant_assessment
  end
end
