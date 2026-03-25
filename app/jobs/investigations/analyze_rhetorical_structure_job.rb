module Investigations
  class AnalyzeRhetoricalStructureJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)

      Pipeline::StepRunner.call(investigation: @investigation, name: "analyze_rhetorical_structure", allow_rerun: true) do
        result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)

        analysis_data = {
          fallacies: result.fallacies.map { |f|
            {
              type: f.type,
              severity: f.severity,
              excerpt: f.excerpt,
              explanation: f.explanation,
              undermined_claim: f.undermined_claim
            }
          },
          narrative_bias_score: result.narrative_bias_score,
          summary: result.summary
        }

        @investigation.update!(rhetorical_analysis: analysis_data)

        {
          fallacies_detected: result.fallacies.size,
          narrative_bias_score: result.narrative_bias_score
        }
      end
    ensure
      if @investigation
        Investigations::AnalyzeContextualGapsJob.perform_later(@investigation.id)
        Investigations::RefreshStatus.call(@investigation)
      end
    end
  end
end
