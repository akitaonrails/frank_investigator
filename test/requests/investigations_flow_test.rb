require "test_helper"

class InvestigationsFlowTest < ActionDispatch::IntegrationTest
  test "renders the homepage" do
    get root_path

    assert_response :success
    assert_includes response.body, "Investigate a news article"
  end

  test "redirects submitted urls to the normalized canonical form" do
    get root_path, params: { url: "HTTPS://Example.COM/news?id=2&a=1#fragment" }

    assert_response :redirect
    assert_includes response.location, "url=https"
  end

  test "creates an investigation and redirects to its permalink" do
    assert_enqueued_with(job: Investigations::KickoffJob) do
      get root_path, params: { url: "https://example.com/news/2025/03/breaking-story" }
    end

    investigation = Investigation.last
    assert_equal "https://example.com/news/2025/03/breaking-story", investigation.normalized_url
    assert_redirected_to investigation_path(investigation)

    follow_redirect!
    assert_response :success
    assert_includes response.body, "turbo-cable-stream-source"
  end
end
