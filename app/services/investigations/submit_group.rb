module Investigations
  class SubmitGroup
    class ConflictError < StandardError; end

    Result = Struct.new(:group, :main_investigation, :investigations, :evidence_sources, :committed_intents, :delivery_deferred, keyword_init: true)
    MAX_LOCK_RETRIES = 3
    RetryableCollision = Class.new(StandardError)

    def self.call(main_url:, news_urls: [], evidence_urls: [], auto_submitted_from: nil, preflight: nil, repair: false, repair_projection: nil)
      new(main_url:, news_urls:, evidence_urls:, auto_submitted_from:, preflight:, repair:, repair_projection:).call
    end

    def initialize(main_url:, news_urls:, evidence_urls:, auto_submitted_from:, preflight: nil, repair: false, repair_projection: nil)
      raise ArgumentError, "main_url must be a URL string" unless main_url.is_a?(String)
      @main_url, @news_urls, @evidence_urls = main_url, news_urls, evidence_urls
      @auto_parent = auto_submitted_from
      @preflight = preflight
      @repair = repair
      @repair_projection = repair_projection
    end

    def call
      validate_supplied_preflight!
      preflight = @preflight || GroupSubmissionPreflight.call(main_url: @main_url, news_urls: @news_urls, evidence_urls: @evidence_urls, repair: @repair)
      return EnsureStarted.call(submitted_url: preflight.main_url, auto_submitted_from: @auto_parent) unless preflight.grouped?
      main, news, evidence = preflight.main_url, preflight.news_urls, preflight.evidence_urls

      result = ApplicationRecord.transaction do
        acquire_submission_locks!(preflight)
        lock_plan_records(preflight)
        raise RetryableCollision, "submission changed while it was being applied" unless preflight.snapshot_valid?
        validate_repair_projection_under_lock!(preflight) if @repair
        main_investigation = ensure_investigation!(main, @auto_parent)
        group = main_investigation.owned_group || create_group!(main_investigation)
        attach_member!(group, main_investigation, @auto_parent ? :auto : :manual)
        members = [ main_investigation ] + news.map { |url| attach_news!(group, url) }
        sources = evidence.map { |url| attach_evidence!(group, url) }
        # Persist delivery intent for every queued member before this domain
        # transaction commits. Post-commit work only claims/enqueues leases.
        members.uniq.each { |investigation| KickoffDelivery.schedule_in_transaction!(investigation) } unless @repair
        intents = []
        if @repair
          sources.each { |source| intents << [ :evidence, source.id ] if projected?(:fetch, source.article.normalized_url) && EvidenceFetchLease.claim_delivery!(source, eligible_at: repair_decision_at) }
          members.uniq.each { |investigation| intents << [ :reconciliation, investigation.id ] if projected?(:reconcile, investigation.slug) && reconciliation_intent!(investigation) }
          intents << [ :enrichment, group.main_investigation_id ] if projected?(:enrich, main_investigation.slug) && EnrichmentLease.claim_group_delivery!(group, eligible_at: repair_decision_at)
        end
        Result.new(group:, main_investigation:, investigations: members.uniq, evidence_sources: sources,
          committed_intents: intents.freeze, delivery_deferred: intents.any?)
      end
      # The durable due markers were written in the domain transaction above.
      # An enclosing caller may still roll that transaction back, so claiming a
      # lease and giving work to an adapter must wait for every transaction.
      ActiveRecord.after_all_transactions_commit do
        result.investigations.each { |investigation| kickoff(investigation) } unless @repair
        deliver_repair_intents(result) if @repair
        result.evidence_sources.each { |source| dispatch_evidence(source) } unless @repair
      end
      result
    rescue GroupSubmissionPreflight::ConflictError => error
      raise ConflictError, error.message
    rescue RetryableCollision, ActiveRecord::RecordNotUnique
      # A concurrent creator committed after our read-only plan. Rebuild the
      # entire plan (never just the failed row) so incompatible same-main
      # requests conflict instead of being silently unioned.
      raise ConflictError, "concurrent submission did not converge; retry" if increment_retry! >= MAX_LOCK_RETRIES
      @preflight = nil
      retry
    rescue ActiveRecord::StatementInvalid => error
      unless error.message.match?(/database is locked|database is busy/i)
        raise
      end
      raise ConflictError, "submission database is busy; retry" if increment_retry! >= MAX_LOCK_RETRIES
      @preflight = nil
      retry
    end

    private

    def lock_plan_records(preflight)
      # Global write-path order (also used by evidence fetch publication):
      # evidence sources, groups, articles, then investigations; every set is
      # sorted by id. This prevents a group submitter from inverting fetch locks.
      member_ids = preflight.members.compact.map(&:id).sort
      # Lock the exact same membership ∪ ownership set validated and snapshotted
      # by preflight. A narrower set lets malformed owned groups evade CAS.
      group_ids = preflight.relevant_groups.map(&:id).sort
      InvestigationGroupEvidenceSource.where(investigation_group_id: group_ids).order(:id).lock.load
      InvestigationGroup.where(id: group_ids).order(:id).lock.load
      Article.where(id: preflight.evidence.compact.map(&:id).sort).order(:id).lock.load
      Investigation.where(id: member_ids).order(:id).lock.load
    end

    def acquire_submission_locks!(preflight)
      preflight.desired_urls.map { |url| Digest::SHA256.hexdigest(url) }.sort.each do |key|
        # No model validation is used here: the unique index is the cross-process
        # authority. Every member gets a fence so shared additional coverage
        # cannot be attached concurrently to different mains.
        lock = InvestigationSubmissionLock.create_or_find_by!(key: key)
        updated = InvestigationSubmissionLock.where(id: lock.id, version: lock.version).update_all(version: lock.version + 1, updated_at: Time.current)
        raise RetryableCollision, "submission lock changed; retry" unless updated == 1
      end
    end


    def ensure_investigation!(url, auto_parent)
      article = EnsureStarted.find_or_create_article!(url)
      Investigation.find_or_create_by!(normalized_url: url) do |record|
        record.submitted_url = url
        record.root_article = article
        record.auto_submitted_from_id = auto_parent.respond_to?(:id) ? auto_parent.id : auto_parent
      end
    end

    def attach_news!(group, url)
      investigation = ensure_investigation!(url, nil)
      attach_member!(group, investigation, :manual)
      investigation
    end

    def attach_member!(group, investigation, kind)
      if investigation.investigation_group_id.present? && investigation.investigation_group_id != group.id
        old_group = investigation.investigation_group
        if GroupSubmissionPreflight.disposable_group?(old_group) && (!@repair || projected?(:destroy, old_group.id))
          investigation.update!(group_reset_attributes.merge(investigation_group: group, group_membership_kind: kind))
          old_group.destroy!
          return
        end
        raise ConflictError, "investigation #{investigation.normalized_url} belongs to another group"
      end
      investigation.update!(investigation_group: group, group_membership_kind: kind) unless investigation.investigation_group_id == group.id && investigation.group_membership_kind == kind.to_s
    end

    def group_reset_attributes
      {
        evidence_revision_assessed: 0, reconciliation_token: nil, reconciliation_revision: nil,
        reconciliation_lease_expires_at: nil, reconciliation_attempts: 0,
        evidence_reconciliation_attempts_revision: nil, evidence_reconciliation_retry_due_at: nil,
        evidence_reconciliation_retry_delivery_token: nil, evidence_reconciliation_retry_delivery_expires_at: nil,
        reconciliation_error: nil, reconciliation_enrichment_pending_revision: nil,
        reconciliation_enrichment_delivered_revision: nil, reconciliation_enrichment_delivery_token: nil,
        reconciliation_enrichment_delivery_expires_at: nil
      }
    end

    def increment_retry!
      @lock_retries = @lock_retries.to_i + 1
    end

    def attach_evidence!(group, url)
      article = EnsureStarted.find_or_create_article!(url)
      source = group.evidence_sources.find_or_create_by!(article: article) do |source|
        source.submitted_url = url
      end
      if @repair && projected?(:reset, url)
        EvidenceFetchLease.reset!(source, at: repair_decision_at)
      end
      EvidenceFetchLease.schedule!(source, at: (@repair ? repair_decision_at : Time.current)) unless @repair && !projected?(:fetch, url)
      source
    end

    def validate_supplied_preflight!
      return unless @preflight
      unless @repair == @preflight.repair? && @preflight.main_url == @main_url &&
          @preflight.news_urls == @news_urls && @preflight.evidence_urls == @evidence_urls
        raise ConflictError, "supplied preflight does not match repair allowlist"
      end
    end

    def reconciliation_intent!(investigation)
      return unless investigation.completed? && ReconciliationLease.current_revision_delivery_eligible?(investigation, eligible_at: repair_decision_at)
      token = ReconciliationLease.claim_current_revision_delivery!(investigation, eligible_at: repair_decision_at) || return
      true
    end

    def repair_decision_at
      @repair_projection.decision_at
    end

    def projected?(kind, value)
      @repair_projection.plan.fetch(:actions).fetch(kind).include?(value)
    end

    # The read-only projection is re-created only after every lock and the
    # ordinary preflight snapshot CAS have succeeded. Any changed input or
    # action rolls back the complete submission, before a group/source exists.
    def validate_repair_projection_under_lock!(preflight)
      raise ConflictError, "repair requires an immutable projection" unless @repair_projection
      unless @repair_projection.mode == :repair && @repair_projection.allowlist == { main: preflight.main_url, news: preflight.news_urls, evidence: preflight.evidence_urls } &&
          @repair_projection.preflight_fingerprint == preflight.fingerprint
        raise ConflictError, "repair projection is not bound to the supplied preflight"
      end
      fresh = GroupSubmissionPreflight.call(main_url: preflight.main_url, news_urls: preflight.news_urls,
        evidence_urls: preflight.evidence_urls, repair: true)
      actual = RepairGroup.projection_for(preflight: fresh, decision_at: repair_decision_at)
      unless actual.input_digest == @repair_projection.input_digest &&
          actual.preflight_fingerprint == @repair_projection.preflight_fingerprint &&
          actual.plan.fetch(:actions) == @repair_projection.plan.fetch(:actions)
        raise ConflictError, "repair projection changed while waiting for locks"
      end
    end

    def kickoff(investigation)
      token = KickoffDelivery.claim!(investigation) || return
      KickoffJob.perform_later(investigation.id, token)
    rescue StandardError
      KickoffDelivery.release!(investigation, token) if token
      raise
    end

    def deliver_repair_intents(result)
      result.committed_intents.each do |kind, id|
        case kind
        when :evidence then FetchEvidenceJob.perform_later(id)
        when :reconciliation then ReconcileGroupEvidenceJob.perform_later(id)
        when :enrichment then RefreshParentEnrichmentJob.perform_later(id)
        end
      end
      # Tokens are deliberately retained as recovery fences. The recovery job
      # redelivers an accepted-but-lost adapter handoff after the lease expires.
    rescue StandardError => error
      Rails.logger.warn("[SubmitGroup] repair delivery deferred: #{error.class}: #{error.message}")
    end

    def dispatch_evidence(source)
      token = EvidenceFetchLease.claim_delivery!(source) || return
      FetchEvidenceJob.perform_later(source.id)
    rescue StandardError
      EvidenceFetchLease.release_delivery!(source, token) if token
      raise
    end

    def create_group!(main_investigation)
      InvestigationGroup.create!(main_investigation: main_investigation)
    end
  end
end
