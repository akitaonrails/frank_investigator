module Investigations
  class DetectCoordinatedNarrativeJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)

      Pipeline::StepRunner.call(investigation: @investigation, name: "detect_coordinated_narrative", allow_rerun: true) do
        result = Analyzers::CoordinatedNarrativeDetector.call(investigation: @investigation)

        narrative_data = {
          coordination_score: result.coordination_score,
          pattern_summary: result.pattern_summary,
          narrative_fingerprint: result.narrative_fingerprint,
          similar_coverage: result.similar_coverage,
          convergent_omissions: result.convergent_omissions,
          convergent_framing: result.convergent_framing
        }

        @investigation.update!(coordinated_narrative: narrative_data)

        { coordination_score: result.coordination_score, coverage_found: result.similar_coverage.size }
      end
    ensure
      if @investigation
        Investigations::ScoreEmotionalManipulationJob.perform_later(@investigation.id)
        Investigations::RefreshStatus.call(@investigation)
      end
    end
  end
end
