module Investigations
  class AnalyzeRhetoricalStructureJob < ApplicationJob
    queue_as :default

    Outcome = Struct.new(:executed, :succeeded, keyword_init: true)

    def perform(investigation_id, reconciliation_token: nil, reconciliation_revision: nil)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)
      reconciliation = reconciliation_token.present?
      return perform_reconciliation(reconciliation_token, reconciliation_revision) if reconciliation

      result = Pipeline::StepRunner.call(investigation: @investigation, name: "analyze_rhetorical_structure", allow_rerun: true) do
        analysis = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
        @investigation.update!(rhetorical_analysis: analysis_data(analysis))

        {
          fallacies_detected: analysis.fallacies.size,
          narrative_bias_score: analysis.narrative_bias_score
        }
      end
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
      # The analyzer can make LLM calls, so it must run before the short lease
      # CAS. No result is persisted until the token and evidence revision win.
      existing_step = @investigation.pipeline_steps.find_by(name: "analyze_rhetorical_structure")
      if existing_step&.running? && existing_step.started_at && existing_step.started_at >= Pipeline::StepRunner::STALE_AFTER.ago
        return Outcome.new(executed: false, succeeded: false)
      end

      analysis = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
      result = ReconciliationLease.publish!(@investigation, token, revision) do
        Pipeline::StepRunner.call(investigation: @investigation, name: "analyze_rhetorical_structure", allow_rerun: true) do
          @investigation.update!(rhetorical_analysis: analysis_data(analysis))
          { fallacies_detected: analysis.fallacies.size, narrative_bias_score: analysis.narrative_bias_score }
        end
      end
      @step_succeeded = result.executed
      Outcome.new(executed: result.executed, succeeded: result.executed)
    end

    def analysis_data(result)
      {
        fallacies: result.fallacies.map { |fallacy|
          { type: fallacy.type, severity: fallacy.severity, excerpt: fallacy.excerpt,
            explanation: fallacy.explanation, undermined_claim: fallacy.undermined_claim }
        },
        narrative_bias_score: result.narrative_bias_score,
        summary: result.summary
      }
    end

    PARALLEL_STEPS = %w[analyze_rhetorical_structure analyze_contextual_gaps detect_coordinated_narrative].freeze

    def enqueue_next_if_converged
      @investigation.reload
      return unless Pipeline::ParallelConvergence.all_completed?(@investigation, PARALLEL_STEPS)

      Investigations::ScoreEmotionalManipulationJob.perform_later(@investigation.id)
    end
  end
end
