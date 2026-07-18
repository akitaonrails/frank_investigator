module Investigations
  class ReconciliationLease
    LEASE_FOR = 5.minutes
    MAX_ATTEMPTS = 4
    Claim = Struct.new(:token, :revision, keyword_init: true)
    class Lost < StandardError; end

    def self.claim(investigation)
      investigation.with_lock do
        investigation.reload
        group = investigation.investigation_group
        return unless group && investigation.evidence_revision_assessed < group.evidence_revision
        return if investigation.reconciliation_lease_expires_at&.future?
        token = SecureRandom.uuid
        revision = group.evidence_revision
        if investigation.evidence_reconciliation_attempts_revision != revision
          investigation.assign_attributes(reconciliation_attempts: 0, reconciliation_error: nil,
            evidence_reconciliation_attempts_revision: revision, evidence_reconciliation_retry_due_at: nil,
            evidence_reconciliation_retry_delivery_token: nil, evidence_reconciliation_retry_delivery_expires_at: nil)
        end
        return if investigation.evidence_reconciliation_retry_due_at&.future? || investigation.reconciliation_attempts >= MAX_ATTEMPTS
        investigation.update!(reconciliation_token: token, reconciliation_revision: revision, reconciliation_lease_expires_at: LEASE_FOR.from_now, reconciliation_attempts: investigation.reconciliation_attempts + 1, reconciliation_error: nil, evidence_reconciliation_retry_due_at: nil, evidence_reconciliation_retry_delivery_token: nil, evidence_reconciliation_retry_delivery_expires_at: nil)
        Claim.new(token:, revision:)
      end
    end

    def self.active?(investigation, token, revision)
      investigation.reconciliation_token == token && investigation.reconciliation_revision == revision && investigation.reconciliation_lease_expires_at&.future? && investigation.investigation_group&.evidence_revision == revision
    end

    # Never call this around computation. It is only a short publication CAS.
    def self.publish!(investigation, token, revision)
      investigation.with_lock do
        investigation.reload
        group = investigation.investigation_group
        raise Lost unless group

        group.with_lock do
          investigation.reload
          group.reload
          raise Lost unless active?(investigation, token, revision)
          yield
        end
      end
    end

    class << self
      alias_method :with_active!, :publish! # compatibility for callers outside reconciliation
    end

    def self.finish!(investigation, token, revision)
      publish!(investigation, token, revision) do
        investigation.update!(
          evidence_revision_assessed: revision,
          reconciliation_enrichment_pending_revision: revision,
          reconciliation_token: nil, reconciliation_revision: nil,
          reconciliation_lease_expires_at: nil, reconciliation_attempts: 0,
          reconciliation_error: nil, evidence_reconciliation_retry_due_at: nil,
          evidence_reconciliation_retry_delivery_token: nil, evidence_reconciliation_retry_delivery_expires_at: nil
        )
      end
      true
    rescue Lost
      false
    end

    def self.fail!(investigation, token, error)
      investigation.with_lock do
        investigation.reload
        return unless investigation.reconciliation_token == token
        attempts = investigation.reconciliation_attempts
        updates = { reconciliation_token: nil, reconciliation_revision: nil, reconciliation_lease_expires_at: nil,
          reconciliation_error: "#{error.class}: #{error.message}".truncate(1000) }
        updates[:evidence_reconciliation_retry_due_at] = (attempts * attempts).seconds.from_now if attempts < MAX_ATTEMPTS
        investigation.update!(updates)
      end
    end

    def self.claim_pending_enrichment!(investigation)
      investigation.with_lock do
        investigation.reload
        revision = investigation.reconciliation_enrichment_pending_revision
        return unless revision && investigation.reconciliation_enrichment_delivered_revision != revision
        return if investigation.reconciliation_enrichment_delivery_expires_at&.future?

        token = SecureRandom.uuid
        investigation.update!(reconciliation_enrichment_delivery_token: token, reconciliation_enrichment_delivery_expires_at: LEASE_FOR.from_now)
        [ token, revision ]
      end
    end

    def self.mark_enrichment_enqueued!(investigation, token, revision)
      investigation.with_lock do
        investigation.reload
        return false unless investigation.reconciliation_enrichment_delivery_token == token && investigation.reconciliation_enrichment_pending_revision == revision
        investigation.update!(reconciliation_enrichment_delivered_revision: revision, reconciliation_enrichment_delivery_token: nil, reconciliation_enrichment_delivery_expires_at: nil)
        true
      end
    end

    def self.release_enrichment_delivery!(investigation, token)
      Investigation.where(id: investigation.id, reconciliation_enrichment_delivery_token: token)
        .update_all(reconciliation_enrichment_delivery_token: nil, reconciliation_enrichment_delivery_expires_at: nil)
    end

    def self.claim_retry_delivery!(investigation, force: false, eligible_at: Time.current, now: nil, at: nil)
      eligible_at = at if at
      investigation.with_lock do
        investigation.reload
        issued_at = now || Time.current
        group = investigation.investigation_group
        return unless group && investigation.evidence_revision_assessed < group.evidence_revision
        return unless investigation.evidence_reconciliation_attempts_revision == group.evidence_revision
        return unless investigation.reconciliation_token.nil? && investigation.reconciliation_attempts < MAX_ATTEMPTS
        return unless force || (investigation.evidence_reconciliation_retry_due_at && investigation.evidence_reconciliation_retry_due_at <= eligible_at)
        return if investigation.evidence_reconciliation_retry_delivery_expires_at && investigation.evidence_reconciliation_retry_delivery_expires_at > eligible_at

        token = SecureRandom.uuid
        investigation.update!(evidence_reconciliation_retry_delivery_token: token, evidence_reconciliation_retry_delivery_expires_at: issued_at + LEASE_FOR)
        token
      end
    end

    # Delivery for a newly advanced evidence revision. This is intentionally
    # separate from a worker failure: publication can commit even when the job
    # adapter is down, and periodic recovery can recreate this durable intent.
    def self.claim_current_revision_delivery!(investigation, eligible_at: Time.current, now: nil)
      investigation.with_lock do
        investigation.reload
        group = investigation.investigation_group
        return unless group && investigation.evidence_revision_assessed < group.evidence_revision
        return if investigation.reconciliation_token.present? || (investigation.evidence_reconciliation_retry_delivery_expires_at && investigation.evidence_reconciliation_retry_delivery_expires_at > eligible_at)
        if investigation.evidence_reconciliation_attempts_revision != group.evidence_revision
          investigation.update!(evidence_reconciliation_attempts_revision: group.evidence_revision,
            reconciliation_attempts: 0, reconciliation_error: nil, evidence_reconciliation_retry_due_at: eligible_at)
        end
      end
      claim_retry_delivery!(investigation, force: true, eligible_at:, now:)
    end

    def self.current_revision_delivery_eligible?(investigation, eligible_at: Time.current, at: nil)
      eligible_at = at if at
      group = investigation.investigation_group
      return false unless group && investigation.evidence_revision_assessed < group.evidence_revision
      return false if investigation.reconciliation_token.present? || (investigation.evidence_reconciliation_retry_delivery_expires_at && investigation.evidence_reconciliation_retry_delivery_expires_at > eligible_at)
      return false unless investigation.pipeline_steps.exists?(name: "generate_summary", status: "completed")
      investigation.evidence_reconciliation_attempts_revision != group.evidence_revision ||
        (investigation.reconciliation_attempts < MAX_ATTEMPTS && (!investigation.evidence_reconciliation_retry_due_at || investigation.evidence_reconciliation_retry_due_at <= eligible_at))
    end

    def self.mark_retry_enqueued!(investigation, token)
      Investigation.where(id: investigation.id, evidence_reconciliation_retry_delivery_token: token)
        .update_all(evidence_reconciliation_retry_delivery_expires_at: LEASE_FOR.from_now) == 1
    end

    def self.release_retry_delivery!(investigation, token)
      Investigation.where(id: investigation.id, evidence_reconciliation_retry_delivery_token: token)
        .update_all(evidence_reconciliation_retry_delivery_token: nil, evidence_reconciliation_retry_delivery_expires_at: nil)
    end
  end
end
