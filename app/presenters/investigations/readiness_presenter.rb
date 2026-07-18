module Investigations
  # The compact, non-recursive representation shared by public and API endpoints.
  class ReadinessPresenter
    def self.call(investigation)
      new(investigation).call
    end

    def initialize(investigation)
      @investigation = investigation
    end

    def call
      { pipeline_ready:, evidence_current:, ready:, group: group_json }
    end

    private

    def pipeline_ready
      @investigation.completed?
    end

    def evidence_current
      return true unless group

      evidence_complete? && manual_members.all? { |member| member.evidence_revision_assessed >= group.evidence_revision }
    end

    def evidence_complete?
      evidence_sources.all? do |source|
        source.ready? || terminal_failure?(source)
      end
    end

    # A rejected/failed fetch is complete only after it is terminal and there is
    # no active or scheduled retry/delivery lease. It remains visible in JSON.
    def terminal_failure?(source)
      source.status.in?(%w[rejected failed]) && source.terminal_at.present? &&
        source.fetch_retry_due_at.blank? && source.fetch_token.blank? &&
        source.fetch_lease_expires_at.blank? && source.fetch_delivery_token.blank? &&
        source.fetch_delivery_expires_at.blank?
    end

    def ready
      pipeline_ready && evidence_current
    end

    def group
      @group ||= @investigation.association(:investigation_group).loaded? ? @investigation.investigation_group : @investigation.investigation_group
    end

    def members
      @members ||= group.investigations.to_a.sort_by do |member|
        [ member.id == group.main_investigation_id ? 0 : 1, member.group_membership_kind.to_s, member.created_at, member.id ]
      end
    end

    def manual_members
      members.select(&:group_membership_kind_manual?)
    end

    def evidence_sources
      @evidence_sources ||= group.evidence_sources.includes(:article).to_a.sort_by { |source| [ source.article&.normalized_url.to_s, source.id ] }
    end

    def group_json
      return nil unless group

      {
        id: group.id,
        main_investigation: { id: group.main_investigation_id, slug: members.find { |member| member.id == group.main_investigation_id }&.slug },
        evidence_revision: group.evidence_revision,
        enriched_revision: group.enriched_revision,
        enrichment_fingerprint: group.enrichment_fingerprint,
        enrichment_applied_fingerprint: group.enrichment_applied_fingerprint,
        created_at: group.created_at,
        updated_at: group.updated_at,
        members: members.map { |member| member_json(member) },
        evidence: evidence_sources.map { |source| evidence_json(source) }
      }
    end

    def member_json(member)
      {
        id: member.id, slug: member.slug, main: member.id == group.main_investigation_id,
        kind: member.group_membership_kind, status: member.status,
        pipeline_ready: member.completed?, evidence_revision_assessed: member.evidence_revision_assessed,
        evidence_current: evidence_current
      }
    end

    def evidence_json(source)
      article = source.article
      {
        id: source.id, submitted_url: source.submitted_url, normalized_url: article&.normalized_url,
        status: source.status, retryable: retryable?(source), ready: source.ready?,
        error: { class: source.last_error_class, message: source.last_error_message },
        classification: { source_kind: article&.source_kind, source_role: article&.source_role },
        created_at: source.created_at, updated_at: source.updated_at, ready_at: source.ready_at,
        terminal_at: source.terminal_at, fetch_retry_due_at: source.fetch_retry_due_at,
        fetch_lease_expires_at: source.fetch_lease_expires_at, fetch_delivery_expires_at: source.fetch_delivery_expires_at
      }
    end

    def retryable?(source)
      source.pending? || source.fetching? || source.fetch_retry_due_at.present? || source.fetch_token.present? || source.fetch_delivery_token.present?
    end
  end
end
