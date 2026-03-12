require "test_helper"

class ArticleFullTest < ActiveSupport::TestCase
  test "evidence_source_type maps government_record" do
    article = Article.new(source_kind: :government_record)
    assert_equal :government_record, article.evidence_source_type
  end

  test "evidence_source_type maps legislative_record to government_record" do
    article = Article.new(source_kind: :legislative_record)
    assert_equal :government_record, article.evidence_source_type
  end

  test "evidence_source_type maps court_record" do
    article = Article.new(source_kind: :court_record)
    assert_equal :court_record, article.evidence_source_type
  end

  test "evidence_source_type maps scientific_paper" do
    article = Article.new(source_kind: :scientific_paper)
    assert_equal :scientific_paper, article.evidence_source_type
  end

  test "evidence_source_type maps company_filing" do
    article = Article.new(source_kind: :company_filing)
    assert_equal :company_filing, article.evidence_source_type
  end

  test "evidence_source_type maps press_release" do
    article = Article.new(source_kind: :press_release)
    assert_equal :press_release, article.evidence_source_type
  end

  test "evidence_source_type defaults to article for news" do
    article = Article.new(source_kind: :news_article)
    assert_equal :article, article.evidence_source_type
  end

  test "evidence_source_type defaults to article for unknown" do
    article = Article.new(source_kind: :unknown)
    assert_equal :article, article.evidence_source_type
  end

  test "primary_source? delegates to authority_tier" do
    primary = Article.new(authority_tier: :primary)
    assert primary.primary_source?

    secondary = Article.new(authority_tier: :secondary)
    assert_not secondary.primary_source?
  end

  test "fetched scope returns only fetched articles" do
    Article.create!(url: "https://af1.com/a", normalized_url: "https://af1.com/a", host: "af1.com", fetch_status: :fetched)
    Article.create!(url: "https://af2.com/a", normalized_url: "https://af2.com/a", host: "af2.com", fetch_status: :pending)

    fetched = Article.fetched
    assert fetched.all? { |a| a.fetched? }
    assert_not fetched.any? { |a| a.pending? }
  end

  test "authoritative_first orders by authority_score desc" do
    low = Article.create!(url: "https://af3.com/a", normalized_url: "https://af3.com/a", host: "af3.com", authority_score: 0.3)
    high = Article.create!(url: "https://af4.com/a", normalized_url: "https://af4.com/a", host: "af4.com", authority_score: 0.9)

    ordered = Article.authoritative_first.where(id: [ low.id, high.id ])
    assert_equal high.id, ordered.first.id
  end
end
