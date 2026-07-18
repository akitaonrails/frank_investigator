module Investigations
  class GenerateSummaryJob < ApplicationJob
    queue_as :default

    Outcome = Struct.new(:executed, :succeeded, keyword_init: true)

    def perform(investigation_id, reconciliation_token: nil, reconciliation_revision: nil)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)
      reconciliation = reconciliation_token.present?

      return perform_reconciliation(reconciliation_token, reconciliation_revision) if reconciliation

      run = lambda do
        stage_result = Pipeline::StepRunner.call(investigation: @investigation, name: "generate_summary", allow_rerun: true) do
          result = Investigations::GenerateSummary.call(investigation: @investigation)

        summary_data = if result
          {
            conclusion: result.conclusion,
            strengths: result.strengths,
            weaknesses: result.weaknesses,
            overall_quality: result.overall_quality
          }
        end

        @investigation.update!(llm_summary: summary_data) if summary_data

        { overall_quality: summary_data&.dig(:overall_quality) }
        end
        if stage_result.executed
          # Generate honest headline after summary (has full context)
          honest = Analyzers::HonestHeadlineGenerator.call(investigation: @investigation)
          @investigation.update_column(:honest_headline, honest) if honest
        end
        stage_result
      end
      result = run.call

      @step_succeeded = result.executed
      Outcome.new(executed: result.executed, succeeded: result.executed)
    ensure
      if @investigation
        Investigations::RefreshStatus.call(@investigation) unless reconciliation
        # Cross-reference is non-blocking enrichment — fire and forget
        Investigations::CrossReferenceJob.perform_later(@investigation.id) if @step_succeeded && !reconciliation
        # If this investigation was auto-submitted as a child of another, feed
        # the parent's enrichment so its event_context and honest_headline
        # reflect this new sibling. Idempotent + lock-serialized inside the job.
        if @step_succeeded && !reconciliation && @investigation.auto_submitted_from_id.present?
          Investigations::RefreshParentEnrichmentJob.perform_later(
            @investigation.auto_submitted_from_id
          )
        end
        # Manual peers are an explicit editorial set, so refresh their shared
        # synthesis even when similarity heuristics would not connect them.
        if @step_succeeded && !reconciliation && @investigation.completed? && @investigation.investigation_group_id.present? && @investigation.group_membership_kind_manual?
          Investigations::RefreshParentEnrichmentJob.perform_later(@investigation.investigation_group.main_investigation_id)
        end
        if @step_succeeded && !reconciliation && @investigation.investigation_group_id && @investigation.group_membership_kind_manual?
          ReconcileGroupEvidenceJob.perform_later(@investigation.id)
        end
      end
    end

    private

    def perform_reconciliation(token, revision)
      # Both generators can make LLM calls; do them before the short publication CAS.
      generated = Investigations::GenerateSummary.call(investigation: @investigation)
      summary_data = if generated
        { conclusion: generated.conclusion, strengths: generated.strengths, weaknesses: generated.weaknesses, overall_quality: generated.overall_quality }
      end
      honest = Analyzers::HonestHeadlineGenerator.call(investigation: @investigation, summary_data:)

      result = ReconciliationLease.publish!(@investigation, token, revision) do
        Pipeline::StepRunner.call(investigation: @investigation, name: "generate_summary", allow_rerun: true) do
          @investigation.update!(llm_summary: summary_data) if summary_data
          @investigation.update_column(:honest_headline, honest) if honest
          { overall_quality: summary_data&.dig(:overall_quality) }
        end
      end
      @step_succeeded = result.executed
      Outcome.new(executed: result.executed, succeeded: result.executed)
    end
  end
end
