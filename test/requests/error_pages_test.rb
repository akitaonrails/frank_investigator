require "test_helper"

class ErrorPagesTest < ActionDispatch::IntegrationTest
  test "shows 404 for nonexistent investigation" do
    get investigation_path(id: 999999)
    assert_response :not_found
  end

  test "shows failure info when investigation has failed" do
    root = Article.create!(url: "https://example.com/err-1", normalized_url: "https://example.com/err-1", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :failed
    )
    PipelineStep.create!(
      investigation: investigation, name: "fetch_root_article", status: :failed,
      error_class: "Fetchers::ChromiumFetcher::FetchError",
      error_message: "Chromium failed to fetch https://example.com/err-1"
    )

    get investigation_path(investigation)
    assert_response :success
    assert_select "section.border-l-verdict-red"
    assert_match(/could not fetch/, response.body)
  end

  test "shows interstitial-specific message for bot detection" do
    root = Article.create!(url: "https://example.com/err-2", normalized_url: "https://example.com/err-2", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :failed
    )
    PipelineStep.create!(
      investigation: investigation, name: "fetch_root_article", status: :failed,
      error_class: "Fetchers::ChromiumFetcher::InterstitialDetectedError",
      error_message: "Interstitial detected"
    )

    get investigation_path(investigation)
    assert_response :success
    assert_match(/bot-detection challenge/, response.body)
  end

  test "shows claim extraction failure message" do
    root = Article.create!(url: "https://example.com/err-3", normalized_url: "https://example.com/err-3", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :failed
    )
    PipelineStep.create!(
      investigation: investigation, name: "extract_claims", status: :failed,
      error_class: "StandardError",
      error_message: "No claims found"
    )

    get investigation_path(investigation)
    assert_response :success
    assert_match(/could not extract any claims/, response.body)
  end

  test "shows not-checkable message when investigation completes with no checkable claims" do
    root = Article.create!(url: "https://example.com/err-4", normalized_url: "https://example.com/err-4", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :completed, checkability_status: :not_checkable
    )
    claim = Claim.create!(canonical_text: "This is opinion.", canonical_fingerprint: "opinion err test", checkability_status: :not_checkable)
    ClaimAssessment.create!(investigation: investigation, claim: claim, checkability_status: :not_checkable, verdict: :not_checkable)

    get investigation_path(investigation)
    assert_response :success
    assert_match(/no verifiable factual claims/, response.body)
  end

  test "does not show failure panel for successful investigation" do
    root = Article.create!(url: "https://example.com/err-5", normalized_url: "https://example.com/err-5", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url,
      root_article: root, status: :completed
    )

    get investigation_path(investigation)
    assert_response :success
    assert_no_match(/Investigation failed/, response.body)
  end

  test "shows error for invalid URL on home page" do
    get root_path(url: "javascript:alert(1)")
    # Should be blocked by either rack-attack (403) or URL validation (422)
    assert_includes [ 403, 422 ], response.status
  end

  test "shows URL too long error" do
    long_url = "https://example.com/#{'a' * 2100}"
    get root_path(url: long_url)
    assert_response :unprocessable_entity
    assert_match(/too long/, response.body)
  end
end
