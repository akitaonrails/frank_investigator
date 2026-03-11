require "test_helper"

class HtmlSnapshotTest < ActiveSupport::TestCase
  test "stores and retrieves compressed HTML" do
    article = Article.create!(
      url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      host: "example.com"
    )

    html = "<html><body><p>Test article content for snapshot storage.</p></body></html>"
    snapshot = HtmlSnapshot.store!(article:, html:, url: article.normalized_url)

    assert snapshot.persisted?
    assert_equal html, snapshot.html
    assert_equal Digest::SHA256.hexdigest(html), snapshot.content_fingerprint
    assert_equal html.bytesize, snapshot.original_size
    assert snapshot.compressed_html.present?
  end

  test "deduplicates by content fingerprint" do
    article = Article.create!(
      url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      host: "example.com"
    )

    html = "<html><body><p>Same content.</p></body></html>"
    first = HtmlSnapshot.store!(article:, html:, url: "https://example.com/test")
    second = HtmlSnapshot.store!(article:, html:, url: "https://example.com/test")

    assert_equal first.id, second.id
    assert_equal 1, HtmlSnapshot.count
  end
end
