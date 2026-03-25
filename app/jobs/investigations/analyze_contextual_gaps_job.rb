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
    ensure
      if @investigation
        Investigations::GenerateSummaryJob.perform_later(@investigation.id)
        Investigations::RefreshStatus.call(@investigation)
      end
    end
  end
end
