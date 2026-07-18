module Investigations
  class ReconcileGroupEvidenceJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      investigation = Investigation.includes(:investigation_group, :pipeline_steps).find(investigation_id)
      group = investigation.investigation_group
      return unless group && investigation.group_membership_kind_manual?
      return if investigation.evidence_revision_assessed >= group.evidence_revision
      return unless investigation.pipeline_steps.exists?(name: "generate_summary", status: "completed")

      lease = ReconciliationLease.claim(investigation)
      return unless lease
      if investigation.claim_assessments.none?
        complete!(investigation, lease)
        return
      end

      run_stage!(investigation, lease, AssessClaimsJob)
      run_stage!(investigation, lease, AnalyzeRhetoricalStructureJob)
      run_stage!(investigation, lease, AnalyzeContextualGapsJob)
      run_stage!(investigation, lease, GenerateSummaryJob)
      complete!(investigation, lease)
    rescue StandardError => error
      ReconciliationLease.fail!(investigation, lease&.token, error) if investigation && lease
      retry_later(investigation) if investigation && lease
    end

    private

    def run_stage!(investigation, lease, job_class)
      outcome = job_class.perform_now(investigation.id, reconciliation_token: lease.token, reconciliation_revision: lease.revision)
      unless outcome.respond_to?(:executed) && outcome.executed && outcome.succeeded
        raise "reconciliation stage did not execute successfully"
      end
      ReconciliationLease.with_active!(investigation, lease.token, lease.revision) { true }
    end

    def complete!(investigation, lease)
      if ReconciliationLease.finish!(investigation, lease.token, lease.revision)
        dispatch_pending_enrichment(investigation)
      else
        retry_later(investigation)
      end
    end

    def retry_later(investigation)
      token = ReconciliationLease.claim_retry_delivery!(investigation, force: true) || return
      due_at = investigation.reload.evidence_reconciliation_retry_due_at
      self.class.set(wait_until: due_at).perform_later(investigation.id)
      ReconciliationLease.mark_retry_enqueued!(investigation, token)
    rescue StandardError
      ReconciliationLease.release_retry_delivery!(investigation, token) if token
    end

    def dispatch_pending_enrichment(investigation)
      token, revision = ReconciliationLease.claim_pending_enrichment!(investigation) || return
      RefreshParentEnrichmentJob.perform_later(investigation.investigation_group.main_investigation_id)
      ReconciliationLease.mark_enrichment_enqueued!(investigation, token, revision)
    rescue StandardError
      ReconciliationLease.release_enrichment_delivery!(investigation, token) if token
      # Acknowledgement already committed the durable pending revision. The
      # scheduled recovery owns delivery after an adapter outage; do not spin a
      # new reconciliation pass merely because an after-commit enqueue failed.
      Rails.logger.warn("[ReconcileGroupEvidence] enrichment trigger delivery deferred for #{investigation.id}")
    end
  end
end
