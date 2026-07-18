module Investigations
  # Durable, short-lock generation protocol for both explicit groups and the
  # legacy auto-child parent. Never wrap computation in these locks.
  class EnrichmentLease
    LEASE_FOR = 5.minutes
    MAX_ATTEMPTS = 4
    Claim = Struct.new(:token, :fingerprint, :members, :manual_members, keyword_init: true)

    def self.group_claim(group)
      group.with_lock do
        group.reload
        manual_members, members = group_snapshot(group)
        fingerprint = group_fingerprint(members, group.evidence_revision)
        return if group.enrichment_applied_fingerprint == fingerprint
        return if group.enrichment_lease_expires_at&.future?
        reset_group_attempts(group, fingerprint)
        return if group.enrichment_retry_due_at&.future? || group.enrichment_attempts >= MAX_ATTEMPTS
        # A singleton has no cross-investigation synthesis. Acknowledge its
        # exact generation without invoking analyzers or scheduling retries.
        if members.size <= 1
          now = Time.current
          manual_members.first&.update_columns(last_enrichment_refresh_at: now, updated_at: now)
          group.update!(enrichment_fingerprint: fingerprint, enrichment_applied_fingerprint: fingerprint,
            enrichment_target_fingerprint: fingerprint, enriched_revision: group.enriched_revision + 1,
            enrichment_attempts: 0, enrichment_error: nil, enrichment_retry_due_at: nil,
            enrichment_delivery_token: nil, enrichment_delivery_expires_at: nil)
          return
        end
        token = SecureRandom.uuid
        group.update!(enrichment_token: token, enrichment_target_fingerprint: fingerprint,
          enrichment_lease_expires_at: LEASE_FOR.from_now, enrichment_attempts: group.enrichment_attempts + 1,
          enrichment_error: nil, enrichment_retry_due_at: nil,
          enrichment_delivery_token: nil, enrichment_delivery_expires_at: nil)
        Claim.new(token:, fingerprint:, members:, manual_members:)
      end
    end

    # Delivery is separate from computation claiming: adapter failure leaves a
    # durable marker that RecoverExpiredGroupLeasesJob can redeliver.
    def self.group_delivery_eligible?(group, eligible_at: Time.current, now: nil)
      eligible_at = now if now
      manuals, members = group_snapshot(group)
      fingerprint = group_fingerprint(members, group.evidence_revision)
      members.size > 1 && group.enrichment_applied_fingerprint != fingerprint &&
        !(group.enrichment_lease_expires_at && group.enrichment_lease_expires_at > eligible_at) && !(group.enrichment_delivery_expires_at && group.enrichment_delivery_expires_at > eligible_at) &&
        !(group.enrichment_retry_due_at && group.enrichment_retry_due_at > eligible_at) && group.enrichment_attempts < MAX_ATTEMPTS
    end

    # Read-only dry-run companion for a group that is about to be assembled.
    # Rejected roots remain members but are intentionally excluded by the same
    # usable-member rule used by group_claim.
    def self.proposed_group_delivery_eligible?(group:, proposed_members:, eligible_at: Time.current, now: nil)
      eligible_at = now if now
      manuals = proposed_members.select { |member| member.group_membership_kind.blank? || member.group_membership_kind_manual? }
        .select { |member| member.completed? && member.root_article&.fetched? && member.root_article.rejection_reason.blank? }
      children = Investigation.where(auto_submitted_from_id: manuals.map(&:id), status: "completed")
        .includes(:root_article, claim_assessments: :claim).order(:id).to_a
        .select { |child| child.root_article&.fetched? && child.root_article.rejection_reason.blank? }
      members = (manuals + children).uniq(&:id).sort_by(&:id)
      return false unless members.size > 1
      return true unless group
      fingerprint = group_fingerprint(members, group.evidence_revision)
      group.enrichment_applied_fingerprint != fingerprint && !(group.enrichment_lease_expires_at && group.enrichment_lease_expires_at > eligible_at) &&
        !(group.enrichment_delivery_expires_at && group.enrichment_delivery_expires_at > eligible_at) && !(group.enrichment_retry_due_at && group.enrichment_retry_due_at > eligible_at) && group.enrichment_attempts < MAX_ATTEMPTS
    end

    def self.claim_group_delivery!(group, eligible_at: Time.current, now: nil)
      group.with_lock do
        group.reload
        issued_at = now || Time.current
        return unless group_delivery_eligible?(group, eligible_at:)
        token = SecureRandom.uuid
        group.update!(enrichment_delivery_token: token, enrichment_delivery_expires_at: issued_at + LEASE_FOR)
        token
      end
    end

    def self.mark_group_enqueued!(group, token)
      InvestigationGroup.where(id: group.id, enrichment_delivery_token: token)
        .update_all(enrichment_delivery_expires_at: LEASE_FOR.from_now) == 1
    end

    def self.release_group_delivery!(group, token)
      InvestigationGroup.where(id: group.id, enrichment_delivery_token: token)
        .update_all(enrichment_delivery_token: nil, enrichment_delivery_expires_at: nil)
    end

    def self.group_publish(group, claim, context, headlines)
      group.with_lock do
        group.reload
        current_manual_members, current_members = group_snapshot(group)
        return :stale unless active_group?(group, claim) && group_fingerprint(current_members, group.evidence_revision) == claim.fingerprint
        now = Time.current
        ApplicationRecord.transaction(requires_new: true) do
          current_manual_members.each do |member|
            member.update!(event_context: context, honest_headline: headlines[member.id].presence || member.honest_headline,
              last_enrichment_refresh_at: now)
          end
          group.update!(enrichment_fingerprint: claim.fingerprint, enrichment_applied_fingerprint: claim.fingerprint,
            enrichment_token: nil, enrichment_lease_expires_at: nil, enrichment_retry_due_at: nil,
            enrichment_error: nil, enriched_revision: group.enriched_revision + 1,
            enrichment_delivery_token: nil, enrichment_delivery_expires_at: nil)
        end
        :published
      end
    end

    def self.group_fail(group, claim, error)
      group.with_lock do
        group.reload
        return unless group.enrichment_token == claim.token && group.enrichment_target_fingerprint == claim.fingerprint
        due = group.enrichment_attempts < MAX_ATTEMPTS ? (group.enrichment_attempts**2).seconds.from_now : nil
        group.update!(enrichment_token: nil, enrichment_lease_expires_at: nil, enrichment_error: "#{error.class}: #{error.message}".truncate(1000), enrichment_retry_due_at: due)
      end
    end

    def self.legacy_claim(parent)
      parent.with_lock do
        parent.reload
        children = completed_auto_children(parent)
        return if children.empty?
        members = [ parent ] + children
        fingerprint = fingerprint_for(members)
        return unless fingerprint && parent.legacy_enrichment_applied_fingerprint != fingerprint
        return if parent.legacy_enrichment_lease_expires_at&.future?
        if parent.legacy_enrichment_target_fingerprint != fingerprint
          parent.assign_attributes(legacy_enrichment_attempts: 0, legacy_enrichment_error: nil, legacy_enrichment_retry_due_at: nil)
        end
        return if parent.legacy_enrichment_retry_due_at&.future? || parent.legacy_enrichment_attempts >= MAX_ATTEMPTS
        token = SecureRandom.uuid
        parent.update!(legacy_enrichment_token: token, legacy_enrichment_target_fingerprint: fingerprint,
          legacy_enrichment_lease_expires_at: LEASE_FOR.from_now, legacy_enrichment_attempts: parent.legacy_enrichment_attempts + 1,
          legacy_enrichment_error: nil, legacy_enrichment_retry_due_at: nil)
        Claim.new(token:, fingerprint:, members:)
      end
    end

    def self.legacy_publish(parent, claim, context, headline)
      parent.with_lock do
        parent.reload
        return :stale unless active_legacy?(parent, claim) && fingerprint_for([ parent ] + completed_auto_children(parent)) == claim.fingerprint
        now = Time.current
        parent.update!(event_context: context, honest_headline: headline.presence || parent.honest_headline,
          last_enrichment_refresh_at: now, legacy_enrichment_applied_fingerprint: claim.fingerprint,
          legacy_enrichment_token: nil, legacy_enrichment_lease_expires_at: nil, legacy_enrichment_retry_due_at: nil,
          legacy_enrichment_error: nil)
        :published
      end
    end

    def self.legacy_fail(parent, claim, error)
      parent.with_lock do
        parent.reload
        return unless parent.legacy_enrichment_token == claim.token && parent.legacy_enrichment_target_fingerprint == claim.fingerprint
        due = parent.legacy_enrichment_attempts < MAX_ATTEMPTS ? (parent.legacy_enrichment_attempts**2).seconds.from_now : nil
        parent.update!(legacy_enrichment_token: nil, legacy_enrichment_lease_expires_at: nil, legacy_enrichment_error: "#{error.class}: #{error.message}".truncate(1000), legacy_enrichment_retry_due_at: due)
      end
    end

    def self.usable_members(group)
      group.investigations.where(status: "completed", group_membership_kind: "manual").includes(:root_article).order(:id).select do |member|
        member.root_article&.fetched? && member.root_article.rejection_reason.blank?
      end
    end

    # Manual peers are the publication audience. Their completed usable
    # lineage children are computation-only coverage inputs, never recipients.
    def self.group_snapshot(group)
      manuals = usable_members(group)
      children = Investigation.where(auto_submitted_from_id: manuals.map(&:id), status: "completed")
        .includes(:root_article, claim_assessments: :claim).order(:id).to_a
        .select { |child| child.root_article&.fetched? && child.root_article.rejection_reason.blank? }
      [ manuals, (manuals + children).uniq(&:id).sort_by(&:id) ]
    end

    def self.group_fingerprint(members, evidence_revision = nil)
      Digest::SHA256.hexdigest({ evidence_revision:, members: investigations_state(members) }.to_json)
    end

    def self.legacy_fingerprint(parent)
      children = completed_auto_children(parent)
      return if children.empty?
      fingerprint_for([ parent ] + children)
    end

    # This mirrors every persisted input read by CrossInvestigationEnricher and
    # HonestHeadlineGenerator. LlmInteraction audit/cache writes are the sole
    # permitted computation-time persistence; no report output is written
    # until group_publish/legacy_publish's final CAS transaction.
    def self.fingerprint_for(investigations)
      Digest::SHA256.hexdigest(investigations_state(investigations).to_json)
    end

    def self.investigations_state(investigations)
      investigations.sort_by(&:id).map { |investigation| state_for(investigation) }
    end
    private_class_method :investigations_state

    def self.state_for(investigation)
      article = investigation.root_article
      claims = investigation.claim_assessments.includes(:claim).map { |assessment|
        [ assessment.claim.canonical_text, assessment.verdict, assessment.confidence_score.to_s ]
      }.sort
      {
        id: investigation.id, slug: investigation.slug,
        analysis_completed_at: investigation.analysis_completed_at&.iso8601(6),
        evidence_revision_assessed: investigation.evidence_revision_assessed,
        article: { title: article&.title, host: article&.host, content_fingerprint: article&.content_fingerprint,
          fetch_status: article&.fetch_status, rejection_reason: article&.rejection_reason },
        headline_bait_score: investigation.headline_bait_score.to_s,
        claims: claims, llm_summary: canonical(investigation.llm_summary),
        contextual_gaps: canonical(investigation.contextual_gaps),
        coordinated_narrative: canonical(investigation.coordinated_narrative)
      }
    end

    def self.active_group?(group, claim)
      group.enrichment_token == claim.token && group.enrichment_target_fingerprint == claim.fingerprint && group.enrichment_lease_expires_at&.future?
    end

    def self.active_legacy?(parent, claim)
      parent.legacy_enrichment_token == claim.token && parent.legacy_enrichment_target_fingerprint == claim.fingerprint && parent.legacy_enrichment_lease_expires_at&.future?
    end

    def self.reset_group_attempts(group, fingerprint)
      return if group.enrichment_target_fingerprint == fingerprint
      group.assign_attributes(enrichment_attempts: 0, enrichment_error: nil, enrichment_retry_due_at: nil)
    end
    private_class_method :reset_group_attempts
    private_class_method :group_snapshot

    def self.completed_auto_children(parent)
      parent.auto_submitted_children.where(status: "completed").includes(:root_article, claim_assessments: :claim).order(:id).to_a
    end
    private_class_method :completed_auto_children

    def self.canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |key| [ key, canonical(value.key?(key) ? value[key] : value[key.to_sym]) ] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end
    private_class_method :canonical
  end
end
