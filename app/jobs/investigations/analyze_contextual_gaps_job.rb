module Investigations
  class AnalyzeContextualGapsJob < ApplicationJob
    queue_as :default

    Outcome = Struct.new(:executed, :succeeded, keyword_init: true)

    def perform(investigation_id, reconciliation_token: nil, reconciliation_revision: nil)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)
      reconciliation = reconciliation_token.present?

      return perform_reconciliation(reconciliation_token, reconciliation_revision) if reconciliation

      run = lambda do
        Pipeline::StepRunner.call(investigation: @investigation, name: "analyze_contextual_gaps", allow_rerun: true) do
        result = Analyzers::ContextualGapAnalyzer.call(investigation: @investigation)

        gaps_data = {
          gaps: result.gaps.map { |g|
            {
              question: g.question,
              relevance: g.relevance,
              search_results: g.search_results.map { |sr|
                { url: sr.url, title: sr.title, snippet: sr.snippet }
              }
            }
          },
          completeness_score: result.completeness_score,
          summary: result.summary
        }

        @investigation.update!(contextual_gaps: gaps_data)

        {
          gaps_found: result.gaps.size,
          completeness_score: result.completeness_score
        }
        end
      end
      result = run.call
      @step_succeeded = result.executed
      Outcome.new(executed: result.executed, succeeded: result.executed)
    ensure
      if @investigation
        enqueue_next_if_converged if @step_succeeded && !reconciliation
        Investigations::RefreshStatus.call(@investigation) unless reconciliation
      end
    end

    private

    def perform_reconciliation(token, revision)
      # Analysis (including search/LLM work) deliberately precedes every DB lock.
      analysis = Analyzers::ContextualGapAnalyzer.call(investigation: @investigation)
      gaps_data = {
        gaps: analysis.gaps.map { |g| { question: g.question, relevance: g.relevance, search_results: g.search_results.map { |sr| { url: sr.url, title: sr.title, snippet: sr.snippet } } } },
        completeness_score: analysis.completeness_score, summary: analysis.summary
      }
      result = ReconciliationLease.publish!(@investigation, token, revision) do
        Pipeline::StepRunner.call(investigation: @investigation, name: "analyze_contextual_gaps", allow_rerun: true) do
          @investigation.update!(contextual_gaps: gaps_data)
          { gaps_found: analysis.gaps.size, completeness_score: analysis.completeness_score }
        end
      end
      @step_succeeded = result.executed
      Outcome.new(executed: result.executed, succeeded: result.executed)
    end

    PARALLEL_STEPS = %w[analyze_rhetorical_structure analyze_contextual_gaps detect_coordinated_narrative].freeze

    def enqueue_next_if_converged
      @investigation.reload
      return unless Pipeline::ParallelConvergence.all_completed?(@investigation, PARALLEL_STEPS)

      Investigations::ScoreEmotionalManipulationJob.perform_later(@investigation.id)
    end
  end
end
