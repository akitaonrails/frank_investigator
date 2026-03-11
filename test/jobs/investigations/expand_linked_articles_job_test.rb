require "test_helper"

class Investigations::ExpandLinkedArticlesJobTest < ActiveJob::TestCase
  test "enqueues fetch jobs for pending links" do
    root = Article.create!(url: "https://example.com/expand", normalized_url: "https://example.com/expand", host: "example.com", fetch_status: :fetched, fetched_at: Time.current)
    target = Article.create!(url: "https://gov.example.com/doc", normalized_url: "https://gov.example.com/doc", host: "gov.example.com", authority_score: 0.9, source_kind: :government_record)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    ArticleLink.create!(source_article: root, target_article: target, href: target.url, depth: 1, follow_status: :pending)

    assert_enqueued_with(job: Investigations::FetchLinkedArticleJob) do
      Investigations::ExpandLinkedArticlesJob.perform_now(investigation.id, source_article_id: root.id)
    end

    assert investigation.pipeline_steps.find_by(name: "expand_linked_articles_root").completed?
  end

  test "respects max depth" do
    root = Article.create!(url: "https://example.com/depth", normalized_url: "https://example.com/depth", host: "example.com", fetch_status: :fetched)
    target = Article.create!(url: "https://deep.example.com", normalized_url: "https://deep.example.com", host: "deep.example.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)
    max_depth = Rails.application.config.x.frank_investigator.max_link_depth
    ArticleLink.create!(source_article: root, target_article: target, href: target.url, depth: max_depth + 1, follow_status: :pending)

    Investigations::ExpandLinkedArticlesJob.perform_now(investigation.id, source_article_id: root.id)

    assert_no_enqueued_jobs only: Investigations::FetchLinkedArticleJob
  end

  test "prioritizes government and primary sources first" do
    root = Article.create!(url: "https://example.com/prio", normalized_url: "https://example.com/prio", host: "example.com", fetch_status: :fetched)
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root, status: :processing)

    gov = Article.create!(url: "https://gov.example.com/a", normalized_url: "https://gov.example.com/a", host: "gov.example.com", source_kind: :government_record, authority_score: 0.95)
    news = Article.create!(url: "https://news.example.com/a", normalized_url: "https://news.example.com/a", host: "news.example.com", source_kind: :news_article, authority_score: 0.6)

    ArticleLink.create!(source_article: root, target_article: news, href: news.url, depth: 1, follow_status: :pending, position: 0)
    ArticleLink.create!(source_article: root, target_article: gov, href: gov.url, depth: 1, follow_status: :pending, position: 1)

    Investigations::ExpandLinkedArticlesJob.perform_now(investigation.id, source_article_id: root.id)

    enqueued = enqueued_jobs.select { |j| j["job_class"] == "Investigations::FetchLinkedArticleJob" }
    assert_equal 2, enqueued.size
  end
end
