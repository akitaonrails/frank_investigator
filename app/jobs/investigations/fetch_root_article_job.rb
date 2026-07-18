module Investigations
  class FetchRootArticleJob < ApplicationJob
    queue_as :fetch

    def perform(investigation_id, kickoff_delivery_token = nil)
      @investigation = Investigation.includes(:root_article).find(investigation_id)
      @article = @investigation.root_article

      result = Pipeline::StepRunner.call(investigation: @investigation, name: "fetch_root_article") do
        raise("Investigation is missing a root article") unless @article

        if @article.fresh?
          Rails.logger.info("[FetchRootArticle] Article #{@article.normalized_url} is fresh (fetched #{@article.fetched_at}), skipping re-fetch")
        else
          @article.reload
          @fetch_generation = @article.content_generation
          begin
            snapshot = fetcher.call(@article.normalized_url)
          rescue Fetchers::ChromiumFetcher::FetchError
            @article.reload
            next({ links_count: @article.sourced_links.count, cached: true, generation_replaced: true }) if @article.fetched? && @article.content_generation > @fetch_generation
            raise
          end
          begin
            Articles::PersistFetchedContent.call(article: @article, html: snapshot.html, fetched_title: snapshot.title, current_depth: 0)
          rescue Articles::PersistFetchedContent::StaleGeneration
            @article.reload
            raise unless @article.fetched? && @article.content_generation > @fetch_generation
          end
          raise "Root article rejected: #{@article.rejection_reason}" unless @article.fetched?
        end

        { links_count: @article.sourced_links.count, cached: @article.fresh? }
      end
      @step_executed = result.executed
      @step_succeeded = result.executed || @investigation.pipeline_steps.exists?(name: "fetch_root_article", status: "completed")
      KickoffDelivery.acknowledge!(@investigation, kickoff_delivery_token) if @step_succeeded && kickoff_delivery_token.present?
    rescue Fetchers::ChromiumFetcher::FetchError => error
      mark_failed_if_current_generation(@investigation.root_article) if @investigation
      raise error
    ensure
      if @investigation
        if (@step_executed || kickoff_delivery_token.present?) && @step_succeeded && @article
          Investigations::ExtractClaimsJob.perform_later(@investigation.id)
          Investigations::AnalyzeHeadlineJob.perform_later(@investigation.id)
          Investigations::ExpandLinkedArticlesJob.perform_later(@investigation.id, source_article_id: @article.id)
        end
        Investigations::RefreshStatus.call(@investigation)
      end
    end

    private

    def fetcher
      Rails.application.config.x.frank_investigator.fetcher_class.constantize
    end

    def mark_failed_if_current_generation(article)
      return unless article && @fetch_generation
      Article.where(id: article.id, content_generation: @fetch_generation).update_all(fetch_status: :failed)
    end
  end
end
