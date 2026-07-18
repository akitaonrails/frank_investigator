module Investigations
  # Periodic, bounded recovery for workers that died after claiming a lease.
  class RecoverExpiredGroupLeasesJob < ApplicationJob
    queue_as :default

    def perform
      recover_reconciliations
      recover_reconciliation_retries
      recover_unassessed_ready_evidence
      recover_reconciliation_enrichment_triggers
      recover_fetches
      recover_kickoffs
      recover_enrichment
      recover_enrichment_deliveries
      recover_legacy_enrichment
    end

    private

    def recover_reconciliations
      Investigation.where.not(reconciliation_token: nil).where("reconciliation_lease_expires_at < ?", Time.current).find_each do |investigation|
        investigation.with_lock do
          next unless investigation.reconciliation_lease_expires_at&.past? && investigation.reconciliation_attempts < ReconciliationLease::MAX_ATTEMPTS
          investigation.update!(reconciliation_token: nil, reconciliation_revision: nil, reconciliation_lease_expires_at: nil)
          ReconcileGroupEvidenceJob.perform_later(investigation.id)
        end
      end
    end

    def recover_reconciliation_retries
      Investigation.where.not(evidence_reconciliation_retry_due_at: nil).where("evidence_reconciliation_retry_due_at <= ?", Time.current).find_each do |investigation|
        token = ReconciliationLease.claim_retry_delivery!(investigation) || next
        ReconcileGroupEvidenceJob.perform_later(investigation.id)
        ReconciliationLease.mark_retry_enqueued!(investigation, token)
      rescue StandardError
        ReconciliationLease.release_retry_delivery!(investigation, token) if token
      end
    end

    def recover_unassessed_ready_evidence
      Investigation.includes(:investigation_group, :pipeline_steps).group_membership_kind_manual.find_each do |investigation|
        group = investigation.investigation_group
        next unless group && investigation.evidence_revision_assessed < group.evidence_revision
        next unless investigation.pipeline_steps.exists?(name: "generate_summary", status: "completed")
        token = ReconciliationLease.claim_current_revision_delivery!(investigation) || next
        ReconcileGroupEvidenceJob.perform_later(investigation.id)
        ReconciliationLease.mark_retry_enqueued!(investigation, token)
      rescue StandardError
        ReconciliationLease.release_retry_delivery!(investigation, token) if token
      end
    end

    def recover_reconciliation_enrichment_triggers
      Investigation.where.not(reconciliation_enrichment_pending_revision: nil).find_each do |investigation|
        token, revision = ReconciliationLease.claim_pending_enrichment!(investigation) || next
        RefreshParentEnrichmentJob.perform_later(investigation.investigation_group.main_investigation_id)
        ReconciliationLease.mark_enrichment_enqueued!(investigation, token, revision)
      rescue StandardError
        ReconciliationLease.release_enrichment_delivery!(investigation, token) if token
      end
    end

    def recover_fetches
      InvestigationGroupEvidenceSource.fetching.where("fetch_lease_expires_at < ?", Time.current).find_each do |source|
        EvidenceFetchLease.expire!(source)
      end
      InvestigationGroupEvidenceSource.pending.where("fetch_retry_due_at <= ?", Time.current).find_each do |source|
        token = EvidenceFetchLease.claim_delivery!(source) || next
        FetchEvidenceJob.perform_later(source.id)
        # Keep the delivery lease as an idempotency fence. A job that is lost is
        # rediscovered after this bounded lease expires.
      rescue StandardError
        EvidenceFetchLease.release_delivery!(source, token) if token
      end
    end

    def recover_kickoffs
      # Older queued rows predate durable kickoff delivery. Backfill only a
      # missing marker; never disturb a future due time or an active lease.
      Investigation.queued.where(kickoff_due_at: nil).find_each do |investigation|
        next if investigation.pipeline_steps.exists?(name: "kickoff")
        investigation.with_lock { KickoffDelivery.schedule_in_transaction!(investigation) }
      end

      Investigation.where(status: %w[queued processing]).where("kickoff_due_at <= ?", Time.current).find_each do |investigation|
        token = KickoffDelivery.claim!(investigation) || next
        if investigation.pipeline_steps.exists?(name: "kickoff", status: "completed")
          FetchRootArticleJob.perform_later(investigation.id, token)
        else
          KickoffJob.perform_later(investigation.id, token)
        end
      rescue StandardError
        KickoffDelivery.release!(investigation, token) if token
      end
    end

    def recover_enrichment
      InvestigationGroup.where.not(enrichment_token: nil).where("enrichment_lease_expires_at < ?", Time.current).find_each do |group|
        group.with_lock do
          next unless group.enrichment_lease_expires_at&.past? && group.enrichment_attempts < EnrichmentLease::MAX_ATTEMPTS
          group.update!(enrichment_token: nil, enrichment_lease_expires_at: nil, enrichment_retry_due_at: Time.current)
        end
      end
      InvestigationGroup.where.not(enrichment_retry_due_at: nil).where("enrichment_retry_due_at <= ?", Time.current).find_each do |group|
        deliver_group_retry(group)
      end
    end

    # A submitter can commit an enrichment delivery token just before its job
    # adapter loses the handoff. Unlike computation leases, this token has no
    # retry due field, so expired unapplied delivery leases are explicit work.
    def recover_enrichment_deliveries
      InvestigationGroup.where.not(enrichment_delivery_token: nil)
        .where("enrichment_delivery_expires_at < ?", Time.current).find_each do |group|
        token = EnrichmentLease.claim_group_delivery!(group) || next
        RefreshParentEnrichmentJob.perform_later(group.main_investigation_id)
        EnrichmentLease.mark_group_enqueued!(group, token)
      rescue StandardError
        # Leave/renew no state here: the old expired token remains eligible for
        # the next bounded recovery pass.
      end
    end

    def recover_legacy_enrichment
      Investigation.where.not(legacy_enrichment_token: nil).where("legacy_enrichment_lease_expires_at < ?", Time.current).find_each do |parent|
        parent.with_lock do
          next unless parent.legacy_enrichment_lease_expires_at&.past? && parent.legacy_enrichment_attempts < EnrichmentLease::MAX_ATTEMPTS
          parent.update!(legacy_enrichment_token: nil, legacy_enrichment_lease_expires_at: nil, legacy_enrichment_retry_due_at: Time.current)
        end
      end
      Investigation.where.not(legacy_enrichment_retry_due_at: nil).where("legacy_enrichment_retry_due_at <= ?", Time.current).find_each do |parent|
        deliver_legacy_retry(parent)
      end
    end

    def deliver_group_retry(group)
      token = nil
      group.with_lock do
        group.reload
        next unless group.enrichment_retry_due_at&.past? && group.enrichment_token.nil? && group.enrichment_attempts < EnrichmentLease::MAX_ATTEMPTS
        next if group.enrichment_delivery_expires_at&.future?
        token = SecureRandom.uuid
        group.update!(enrichment_delivery_token: token, enrichment_delivery_expires_at: EnrichmentLease::LEASE_FOR.from_now)
      end
      return unless token
      RefreshParentEnrichmentJob.perform_later(group.main_investigation_id)
      InvestigationGroup.where(id: group.id, enrichment_delivery_token: token).update_all(enrichment_delivery_expires_at: EnrichmentLease::LEASE_FOR.from_now)
    rescue StandardError
      InvestigationGroup.where(id: group.id, enrichment_delivery_token: token).update_all(enrichment_delivery_token: nil, enrichment_delivery_expires_at: nil) if token
    end

    def deliver_legacy_retry(parent)
      token = nil
      parent.with_lock do
        parent.reload
        next unless parent.legacy_enrichment_retry_due_at&.past? && parent.legacy_enrichment_token.nil? && parent.legacy_enrichment_attempts < EnrichmentLease::MAX_ATTEMPTS
        next if parent.legacy_enrichment_delivery_expires_at&.future?
        token = SecureRandom.uuid
        parent.update!(legacy_enrichment_delivery_token: token, legacy_enrichment_delivery_expires_at: EnrichmentLease::LEASE_FOR.from_now)
      end
      return unless token
      RefreshParentEnrichmentJob.perform_later(parent.id)
      Investigation.where(id: parent.id, legacy_enrichment_delivery_token: token).update_all(legacy_enrichment_delivery_expires_at: EnrichmentLease::LEASE_FOR.from_now)
    rescue StandardError
      Investigation.where(id: parent.id, legacy_enrichment_delivery_token: token).update_all(legacy_enrichment_delivery_token: nil, legacy_enrichment_delivery_expires_at: nil) if token
    end
  end
end
