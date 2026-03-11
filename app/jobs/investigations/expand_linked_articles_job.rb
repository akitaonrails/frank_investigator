module Investigations
  class ExpandLinkedArticlesJob < ApplicationJob
    queue_as :default

    def perform(investigation_id, source_article_id:)
      investigation = Investigation.find(investigation_id)
      source_article = Article.includes(:sourced_links).find(source_article_id)

      Pipeline::StepRunner.call(investigation:, name: step_name(investigation, source_article_id)) do
        max_depth = Rails.application.config.x.frank_investigator.max_link_depth
        links = prioritized_links(source_article, max_depth)

        links.each do |link|
          FetchLinkedArticleJob.perform_later(investigation.id, link.id)
        end

        { enqueued_links_count: links.count }
      end
    ensure
      Investigations::RefreshStatus.call(investigation) if investigation
    end

    private

    def step_name(investigation, source_article_id)
      source_article_id == investigation.root_article_id ? "expand_linked_articles_root" : "expand_linked_articles:#{source_article_id}"
    end

    def prioritized_links(source_article, max_depth)
      source_article.sourced_links.includes(:target_article).where(depth: ..max_depth, follow_status: "pending").to_a
        .sort_by { |link| [source_priority(link.target_article), -link.target_article.authority_score.to_f, link.depth, link.position] }
        .first(10)
    end

    def source_priority(article)
      case article.source_kind
      when "government_record", "legislative_record", "court_record", "scientific_paper", "company_filing" then 0
      when "press_release" then 1
      when "news_article" then 2
      else
        3
      end
    end
  end
end
