require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  test "validates presence of url, normalized_url, host" do
    article = Article.new
    assert_not article.valid?
    assert_includes article.errors[:url], "can't be blank"
    assert_includes article.errors[:normalized_url], "can't be blank"
    assert_includes article.errors[:host], "can't be blank"
  end

  test "validates uniqueness of normalized_url" do
    Article.create!(url: "https://a.com/1", normalized_url: "https://a.com/1", host: "a.com")
    dup = Article.new(url: "https://a.com/2", normalized_url: "https://a.com/1", host: "a.com")
    assert_not dup.valid?
    assert_includes dup.errors[:normalized_url], "has already been taken"
  end

  test "fetch_status defaults to pending" do
    article = Article.create!(url: "https://b.com/1", normalized_url: "https://b.com/1", host: "b.com")
    assert article.pending?
  end

  test "fetched scope returns only fetched articles" do
    Article.create!(url: "https://c.com/1", normalized_url: "https://c.com/1", host: "c.com", fetch_status: :fetched)
    Article.create!(url: "https://c.com/2", normalized_url: "https://c.com/2", host: "c.com", fetch_status: :pending)

    assert_equal 1, Article.fetched.count
  end

  test "primary_source? returns true for primary tier" do
    article = Article.new(authority_tier: :primary)
    assert article.primary_source?
  end

  test "evidence_source_type maps source_kind correctly" do
    assert_equal :government_record, Article.new(source_kind: :government_record).evidence_source_type
    assert_equal :government_record, Article.new(source_kind: :legislative_record).evidence_source_type
    assert_equal :court_record, Article.new(source_kind: :court_record).evidence_source_type
    assert_equal :article, Article.new(source_kind: :news_article).evidence_source_type
  end

  test "source_role enum accepts all defined values" do
    %i[unknown official_position authenticated_legal_text neutral_statistics oversight research_discovery news_reporting].each do |role|
      article = Article.new(url: "https://x.com", normalized_url: "https://x.com/#{role}", host: "x.com", source_role: role)
      assert article.valid?, "Expected source_role #{role} to be valid"
    end
  end
end
