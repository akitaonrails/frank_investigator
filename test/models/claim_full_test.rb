require "test_helper"

class ClaimFullTest < ActiveSupport::TestCase
  test "prior_variant_assessment returns parent assessment" do
    parent = Claim.create!(canonical_text: "Parent claim", canonical_fingerprint: "pva_parent_#{SecureRandom.hex(4)}")
    variant = Claim.create!(canonical_text: "Variant of parent", canonical_fingerprint: "pva_variant_#{SecureRandom.hex(4)}", canonical_parent: parent)

    root = Article.create!(url: "https://pva.com/a", normalized_url: "https://pva.com/a", host: "pva.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    parent_assessment = ClaimAssessment.create!(
      investigation:, claim: parent,
      verdict: :supported, confidence_score: 0.8, checkability_status: :checkable
    )

    result = variant.prior_variant_assessment
    assert_equal parent_assessment.id, result.id
  end

  test "prior_variant_assessment returns nil without parent" do
    claim = Claim.create!(canonical_text: "No parent", canonical_fingerprint: "pva_none_#{SecureRandom.hex(4)}")
    assert_nil claim.prior_variant_assessment
  end

  test "prior_variant_assessment returns sibling assessment when parent has none" do
    parent = Claim.create!(canonical_text: "Parent 2", canonical_fingerprint: "pva_p2_#{SecureRandom.hex(4)}")
    sibling = Claim.create!(canonical_text: "Sibling claim", canonical_fingerprint: "pva_sib_#{SecureRandom.hex(4)}", canonical_parent: parent)
    variant = Claim.create!(canonical_text: "Variant claim", canonical_fingerprint: "pva_var2_#{SecureRandom.hex(4)}", canonical_parent: parent)

    root = Article.create!(url: "https://pva2.com/a", normalized_url: "https://pva2.com/a", host: "pva2.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    sibling_assessment = ClaimAssessment.create!(
      investigation:, claim: sibling,
      verdict: :disputed, confidence_score: 0.7, checkability_status: :checkable
    )

    result = variant.prior_variant_assessment
    assert_equal sibling_assessment.id, result.id
  end

  test "prior_variant_assessment skips pending assessments" do
    parent = Claim.create!(canonical_text: "Parent 3", canonical_fingerprint: "pva_p3_#{SecureRandom.hex(4)}")
    variant = Claim.create!(canonical_text: "Variant 3", canonical_fingerprint: "pva_v3_#{SecureRandom.hex(4)}", canonical_parent: parent)

    root = Article.create!(url: "https://pva3.com/a", normalized_url: "https://pva3.com/a", host: "pva3.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    ClaimAssessment.create!(investigation:, claim: parent, verdict: :pending, confidence_score: 0.0)

    assert_nil variant.prior_variant_assessment
  end

  test "variants association links back to parent" do
    parent = Claim.create!(canonical_text: "P", canonical_fingerprint: "var_p_#{SecureRandom.hex(4)}")
    v1 = Claim.create!(canonical_text: "V1", canonical_fingerprint: "var_v1_#{SecureRandom.hex(4)}", canonical_parent: parent)
    v2 = Claim.create!(canonical_text: "V2", canonical_fingerprint: "var_v2_#{SecureRandom.hex(4)}", canonical_parent: parent)

    assert_equal 2, parent.variants.count
    assert_includes parent.variants, v1
    assert_includes parent.variants, v2
    assert_equal parent, v1.canonical_parent
  end
end
