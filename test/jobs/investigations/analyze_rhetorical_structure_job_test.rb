require "test_helper"

class Investigations::AnalyzeRhetoricalStructureJobTest < ActiveSupport::TestCase
  test "runs rhetorical analysis and stores result on investigation" do
    root = Article.create!(
      url: "https://rhet.com/article", normalized_url: "https://rhet.com/article",
      host: "rhet.com", fetch_status: :fetched,
      body_text: "This article presents data but then pivots to undermine it. In my 30 years of experience, this is wrong.",
      title: "Test Article"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )
    claim = Claim.create!(canonical_text: "Rhetorical test", canonical_fingerprint: "rhet_#{SecureRandom.hex(4)}", checkability_status: :checkable)
    ClaimAssessment.create!(investigation:, claim:, verdict: :supported, confidence_score: 0.8, checkability_status: :checkable)

    Investigations::AnalyzeRhetoricalStructureJob.perform_now(investigation.id)

    investigation.reload
    assert investigation.rhetorical_analysis.present?
    assert investigation.rhetorical_analysis.key?("fallacies")
    assert investigation.rhetorical_analysis.key?("narrative_bias_score")
    assert investigation.rhetorical_analysis.key?("summary")
  end

  test "refreshes investigation status after completion" do
    root = Article.create!(
      url: "https://rhet2.com/article", normalized_url: "https://rhet2.com/article",
      host: "rhet2.com", fetch_status: :fetched,
      body_text: "Simple factual content without rhetorical issues.",
      title: "Clean Article"
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :processing
    )

    Investigations::AnalyzeRhetoricalStructureJob.perform_now(investigation.id)

    step = investigation.pipeline_steps.find_by(name: "analyze_rhetorical_structure")
    assert_equal "completed", step.status
  end
end
