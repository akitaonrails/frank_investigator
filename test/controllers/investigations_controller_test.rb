require "test_helper"

class InvestigationsControllerTest < ActionDispatch::IntegrationTest
  test "renders home page" do
    get root_path
    assert_response :success
  end

  test "rejects social media URLs" do
    get root_path, params: { url: "https://twitter.com/user/status/123456" }
    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("investigations.url_rejected.social_media")
  end

  test "rejects homepage URLs" do
    get root_path, params: { url: "https://g1.globo.com" }
    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("investigations.url_rejected.index_page")
  end

  test "rejects section page URLs" do
    get root_path, params: { url: "https://g1.globo.com/economia" }
    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("investigations.url_rejected.section_page")
  end

  test "rejects ecommerce URLs" do
    get root_path, params: { url: "https://www.amazon.com/dp/B09V3KXJPB" }
    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("investigations.url_rejected.ecommerce")
  end

  test "rejects URLs that are too long" do
    long_url = "https://example.com/article/" + ("a" * 2100)
    get root_path, params: { url: long_url }
    assert_response :unprocessable_entity
  end

  test "rejects blank URL" do
    get root_path, params: { url: "" }
    assert_response :success # renders home with no error (blank = no submission)
  end

  test "accepts valid article URL and redirects" do
    assert_enqueued_with(job: Investigations::KickoffJob) do
      get root_path, params: { url: "https://example.com/news/2025/03/article-slug" }
    end
    assert_response :redirect
  end

  test "show page renders for existing investigation" do
    root = Article.create!(url: "https://ct.com/show", normalized_url: "https://ct.com/show", host: "ct.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :completed)

    get investigation_path(investigation)
    assert_response :success
    assert_includes response.body, "turbo-cable-stream-source"
  end

  test "show page displays failure info for failed investigation" do
    root = Article.create!(url: "https://ct.com/fail", normalized_url: "https://ct.com/fail", host: "ct.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :failed)
    investigation.pipeline_steps.create!(
      name: "fetch_root_article", status: :failed,
      error_class: "Fetchers::ChromiumFetcher::FetchError",
      error_message: "Connection refused"
    )

    get investigation_path(investigation)
    assert_response :success
    assert_includes response.body, I18n.t("investigations.show.investigation_failed")
  end

  test "show page returns 404 for missing investigation" do
    get investigation_path(id: 999999)
    assert_response :not_found
  end

  test "graph_data returns JSON" do
    root = Article.create!(url: "https://ct.com/graph", normalized_url: "https://ct.com/graph", host: "ct.com", fetch_status: :fetched, title: "Root")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)

    get graph_data_investigation_path(investigation), as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("nodes")
    assert data.key?("edges")
  end
end
