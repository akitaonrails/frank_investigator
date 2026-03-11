require "test_helper"

class GraphDataTest < ActionDispatch::IntegrationTest
  test "returns JSON with nodes and edges" do
    root = Article.create!(
      url: "https://example.com/graph", normalized_url: "https://example.com/graph",
      host: "example.com", title: "Graph Test Article", fetch_status: :fetched
    )
    target = Article.create!(
      url: "https://source.com/doc", normalized_url: "https://source.com/doc",
      host: "source.com", title: "Source Document", fetch_status: :fetched,
      source_kind: :government_record, authority_tier: :primary, authority_score: 0.95
    )
    investigation = Investigation.create!(
      submitted_url: root.url, normalized_url: root.normalized_url, root_article: root
    )
    ArticleLink.create!(source_article: root, target_article: target, href: target.url, anchor_text: "Official doc")

    get graph_data_investigation_path(investigation), as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?("nodes")
    assert data.key?("edges")
    assert data["nodes"].any? { |n| n["kind"] == "root" }
    assert data["nodes"].any? { |n| n["kind"] == "source" }
    assert data["edges"].any?
  end

  test "returns empty graph for investigation without root article" do
    investigation = Investigation.create!(
      submitted_url: "https://example.com/empty-graph",
      normalized_url: "https://example.com/empty-graph"
    )

    get graph_data_investigation_path(investigation), as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert_empty data["nodes"]
    assert_empty data["edges"]
  end
end
