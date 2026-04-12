module Investigations
  class RefreshFromSnapshots
    ANALYSIS_COLUMNS = %i[
      source_misrepresentation
      temporal_manipulation
      statistical_deception
      selective_quotation
      authority_laundering
      rhetorical_analysis
      contextual_gaps
      coordinated_narrative
      emotional_manipulation
      llm_summary
      honest_headline
      event_context
    ].freeze

    PIPELINE_STEPS = %w[
      extract_claims
      analyze_headline
      assess_claims
      expand_linked_articles_root
      detect_source_misrepresentation
      detect_temporal_manipulation
      detect_statistical_deception
      detect_selective_quotation
      detect_authority_laundering
      analyze_rhetorical_structure
      analyze_contextual_gaps
      detect_coordinated_narrative
      score_emotional_manipulation
      generate_summary
    ].freeze

    def self.call(investigation:, refresh_linked_articles: true)
      new(investigation:, refresh_linked_articles:).call
    end

    def initialize(investigation:, refresh_linked_articles:)
      @investigation = investigation
      @refresh_linked_articles = refresh_linked_articles
    end

    def call
      raise "Investigation is missing a root article" unless @investigation.root_article

      refresh_articles!
      reset_pipeline_state!
      rebuild_pipeline!

      @investigation.reload
    end

    private

    def refresh_articles!
      articles_to_refresh.each do |article|
        refresh_article!(article)
      end
    end

    def articles_to_refresh
      articles = [ @investigation.root_article ]
      if @refresh_linked_articles
        articles.concat(@investigation.root_article.sourced_links.includes(:target_article).map(&:target_article))
      end
      articles.compact.uniq
    end

    def refresh_article!(article)
      snapshot = HtmlSnapshot.where(article: article).order(captured_at: :desc).first
      if snapshot
        Articles::PersistFetchedContent.call(
          article:,
          html: snapshot.html,
          fetched_title: article.title,
          current_depth: article.id == @investigation.root_article_id ? 0 : 1
        )
      else
        refresh_source_metadata!(article)
      end
    end

    def refresh_source_metadata!(article)
      metadata = Sources::AuthorityClassifier.call(url: article.normalized_url, host: article.host, title: article.title)
      article.update!(
        source_kind: metadata.source_kind,
        authority_tier: metadata.authority_tier,
        authority_score: metadata.authority_score,
        independence_group: metadata.independence_group,
        source_role: metadata.source_role || :unknown
      )
    end

    def reset_pipeline_state!
      ApplicationRecord.transaction do
        LlmInteraction.where(investigation: @investigation).destroy_all
        @investigation.root_article.article_claims.destroy_all
        @investigation.claim_assessments.destroy_all
        @investigation.pipeline_steps.where(name: PIPELINE_STEPS).destroy_all
        @investigation.update!(
          status: :processing,
          headline_bait_score: 0,
          **ANALYSIS_COLUMNS.index_with { nil }
        )
      end
    end

    def rebuild_pipeline!
      run_extract_claims_step!
      run_expand_root_step!
      Investigations::AnalyzeHeadlineJob.perform_now(@investigation.id)
      Investigations::AssessClaimsJob.perform_now(@investigation.id)
      Investigations::BatchContentAnalysisJob.perform_now(@investigation.id)
      Investigations::AnalyzeRhetoricalStructureJob.perform_now(@investigation.id)
      Investigations::AnalyzeContextualGapsJob.perform_now(@investigation.id)
      Investigations::DetectCoordinatedNarrativeJob.perform_now(@investigation.id)
      Investigations::ScoreEmotionalManipulationJob.perform_now(@investigation.id)
      Investigations::GenerateSummaryJob.perform_now(@investigation.id)
      Investigations::CrossReferenceJob.perform_now(@investigation.id)
      Investigations::RefreshStatus.call(@investigation.reload)
    end

    def run_extract_claims_step!
      Pipeline::StepRunner.call(investigation: @investigation, name: "extract_claims", allow_rerun: true) do
        Articles::SyncClaims.call(investigation: @investigation, article: @investigation.root_article)
        { claims_count: @investigation.claim_assessments.count }
      end
    end

    def run_expand_root_step!
      Pipeline::StepRunner.call(investigation: @investigation, name: "expand_linked_articles_root", allow_rerun: true) do
        pending_links = @investigation.root_article.sourced_links.where(follow_status: "pending").count
        { pending_links_count: pending_links }
      end
    end
  end
end
