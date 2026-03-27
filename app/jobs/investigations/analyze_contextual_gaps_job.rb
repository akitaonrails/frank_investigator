module Investigations
  class AnalyzeContextualGapsJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)

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
      @step_succeeded = true
    ensure
      if @investigation
        enqueue_next_if_converged if @step_succeeded
        Investigations::RefreshStatus.call(@investigation)
      end
    end

    private

    PARALLEL_STEPS = %w[analyze_rhetorical_structure analyze_contextual_gaps detect_coordinated_narrative].freeze

    def enqueue_next_if_converged
      @investigation.reload
      return unless Pipeline::ParallelConvergence.all_completed?(@investigation, PARALLEL_STEPS)

      Investigations::ScoreEmotionalManipulationJob.perform_later(@investigation.id)
    end
  end
end
