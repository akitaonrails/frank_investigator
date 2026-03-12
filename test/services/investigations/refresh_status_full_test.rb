require "test_helper"

class Investigations::RefreshStatusFullTest < ActiveSupport::TestCase
  test "sets processing when some steps are running" do
    root = Article.create!(url: "https://r.com/rs1", normalized_url: "https://r.com/rs1", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    investigation.pipeline_steps.create!(name: "fetch_root_article", status: :completed, finished_at: Time.current)
    investigation.pipeline_steps.create!(name: "extract_claims", status: :running, started_at: Time.current)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "processing", investigation.status
    assert_nil investigation.analysis_completed_at
  end

  test "sets queued when no steps exist" do
    root = Article.create!(url: "https://r.com/rs2", normalized_url: "https://r.com/rs2", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "queued", investigation.status
  end

  test "sets not_checkable when all claims are not_checkable" do
    root = Article.create!(url: "https://r.com/rs3", normalized_url: "https://r.com/rs3", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    c1 = Claim.create!(canonical_text: "NC1", canonical_fingerprint: "rs_nc1_#{SecureRandom.hex(4)}")
    ClaimAssessment.create!(investigation:, claim: c1, checkability_status: :not_checkable)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "not_checkable", investigation.checkability_status
  end

  test "sets checkable when all claims are checkable" do
    root = Article.create!(url: "https://r.com/rs4", normalized_url: "https://r.com/rs4", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    c1 = Claim.create!(canonical_text: "CK1", canonical_fingerprint: "rs_ck1_#{SecureRandom.hex(4)}")
    ClaimAssessment.create!(investigation:, claim: c1, checkability_status: :checkable)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "checkable", investigation.checkability_status
  end

  test "sets pending when no assessments exist" do
    root = Article.create!(url: "https://r.com/rs5", normalized_url: "https://r.com/rs5", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal "pending", investigation.checkability_status
  end

  test "generates summary text from assessments" do
    root = Article.create!(url: "https://r.com/rs6", normalized_url: "https://r.com/rs6", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    c1 = Claim.create!(canonical_text: "Sum1", canonical_fingerprint: "rs_sum1_#{SecureRandom.hex(4)}")
    c2 = Claim.create!(canonical_text: "Sum2", canonical_fingerprint: "rs_sum2_#{SecureRandom.hex(4)}")
    ClaimAssessment.create!(investigation:, claim: c1, checkability_status: :checkable, verdict: :supported)
    ClaimAssessment.create!(investigation:, claim: c2, checkability_status: :not_checkable, verdict: :not_checkable)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_includes investigation.summary, "1 checkable claims"
    assert_includes investigation.summary, "1 not checkable"
  end

  test "returns nil summary when no assessments" do
    root = Article.create!(url: "https://r.com/rs7", normalized_url: "https://r.com/rs7", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_nil investigation.summary
  end

  test "returns zero confidence when no assessments" do
    root = Article.create!(url: "https://r.com/rs8", normalized_url: "https://r.com/rs8", host: "r.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)

    Investigations::RefreshStatus.call(investigation)
    investigation.reload

    assert_equal 0, investigation.overall_confidence_score
  end
end
