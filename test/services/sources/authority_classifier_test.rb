require "test_helper"

class Sources::AuthorityClassifierTest < ActiveSupport::TestCase
  test "classifies government sources as primary" do
    result = Sources::AuthorityClassifier.call(
      url: "https://www.sec.gov/ixviewer/ix.html?doc=/Archives/edgar/data/example.htm",
      host: "www.sec.gov",
      title: "8-K filing"
    )

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_operator result.authority_score, :>=, 0.9
    assert_equal "sec.gov", result.independence_group
  end

  test "classifies social hosts as low authority" do
    result = Sources::AuthorityClassifier.call(
      url: "https://x.com/example/status/123",
      host: "x.com",
      title: "Post"
    )

    assert_equal :social_post, result.source_kind
    assert_equal :low, result.authority_tier
    assert_operator result.authority_score, :<, 0.3
  end
end
