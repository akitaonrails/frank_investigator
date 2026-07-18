module Investigations
  # Operator-only, deliberately narrow wrapper around the normal group submitter.
  # It never invents investigations: the allowlist is the complete desired state.
  class RepairGroup
    class ConflictError < StandardError; end
    # A dry projection is allowed to be replayed a few seconds later, but a
    # future operator clock must never manufacture future eligibility.
    CLOCK_SKEW_TOLERANCE = 5.seconds

    attr_reader :preflight

    def self.call(main:, news:, evidence_urls:, apply: false, preflight: nil, expected_digest: nil, decision_at: nil)
      new(main:, news:, evidence_urls:, apply:, preflight:, expected_digest:, decision_at:).call
    end

    def initialize(main:, news:, evidence_urls:, apply:, preflight: nil, expected_digest: nil, decision_at: nil)
      @main, @news, @evidence_urls, @apply, @preflight = main, news, evidence_urls, apply, preflight
      @expected_digest = expected_digest
      @decision_at = decision_at
    end

    def call
      validate_supplied_preflight!
      @preflight ||= GroupSubmissionPreflight.call(main_url: @main.normalized_url,
        news_urls: @news.map(&:normalized_url), evidence_urls: @evidence_urls, repair: true)
      projection = self.class.projection_for(preflight: @preflight, decision_at: (@decision_at ||= Time.current))
      planned = projection.to_h
      return projection unless @apply
      raise ConflictError, "decision_at is too far in the future" if projection.decision_at > Time.current + CLOCK_SKEW_TOLERANCE
      raise ConflictError, "EXPECTED_DIGEST is required for apply" if @expected_digest.blank?
      raise ConflictError, "EXPECTED_DIGEST does not match repair projection" unless ActiveSupport::SecurityUtils.secure_compare(@expected_digest, projection.action_digest)

      # SubmitGroup owns locks, CAS revalidation, durable delivery and all writes.
      result = SubmitGroup.call(main_url: @preflight.main_url, news_urls: @preflight.news_urls,
        evidence_urls: @preflight.evidence_urls, preflight: @preflight, repair: true, repair_projection: projection)
      deep_freeze(planned.except(:planned_intents, :will_require_delivery).merge(applied: true, committed_intents: result.committed_intents,
        delivery_managed_by_recovery: result.delivery_deferred))
    rescue SubmitGroup::ConflictError, GroupSubmissionPreflight::ConflictError => error
      raise ConflictError, error.message
    end

    def plan
      desired = @preflight.desired_urls
      groups = @preflight.relevant_groups
      {
        fingerprint: @preflight.fingerprint,
        current_owner: groups.map { |g| [ g.id, g.main_investigation&.slug ] }.sort,
        proposed_owner: @main.slug,
        members: desired.zip(@preflight.members).map { |url, inv| { slug: inv.slug, url:, role: "manual", status: inv.status, root_status: inv.root_article&.fetch_status } },
        evidence: @preflight.evidence_urls.zip(@preflight.evidence).map { |url, article|
          source = source_for(article)
          { url:, status: source&.status || "new", article_id: article&.id, article_reuse: article.present? }
        },
        groups_destroyed: groups.select { |g| GroupSubmissionPreflight.disposable_group?(g) && g.main_investigation_id != @main.id }.map(&:id).sort,
        resets: reset_urls,
        reconciliation: reconciliation_slugs,
        enrichment: projected_enrichment,
        planned_jobs: planned_jobs,
        warnings: @preflight.warnings,
        conflicts: []
      }
    end

    def self.projection_for(preflight:, decision_at:)
      instance = allocate
      instance.instance_variable_set(:@preflight, preflight)
      instance.instance_variable_set(:@main, preflight.members.first)
      instance.instance_variable_set(:@decision_at, decision_at)
      instance.send(:build_projection)
    end

    def build_projection
      RepairProjection.new(decision_at: @decision_at,
        allowlist: { main: @preflight.main_url, news: @preflight.news_urls, evidence: @preflight.evidence_urls },
        preflight_fingerprint: @preflight.fingerprint, planning_input: planning_input,
        plan: plan.merge(fingerprint: @preflight.fingerprint, actions: actions,
          planned_intents: planned_intents, will_require_delivery: planned_intents.any?))
    end

    private

    def validate_supplied_preflight!
      return unless @preflight
      expected = GroupSubmissionPreflight.call(main_url: @main.normalized_url, news_urls: @news.map(&:normalized_url),
        evidence_urls: @evidence_urls, repair: true)
      unless @preflight.repair? && @preflight.main_url == expected.main_url &&
          @preflight.news_urls.sort == expected.news_urls.sort && @preflight.evidence_urls.sort == expected.evidence_urls.sort
        raise ConflictError, "supplied preflight does not match repair allowlist"
      end
      raise ConflictError, "supplied preflight snapshot is stale" unless @preflight.fingerprint == expected.fingerprint && @preflight.snapshot_valid?
    end

    def reset_urls
      @preflight.evidence.compact.select { |article|
        source = source_for(article)
        source && EvidenceFetchLease.reset_required?(source, at: @decision_at || Time.current)
      }.map(&:normalized_url).sort
    end

    def source_for(article)
      return unless article
      @preflight.relevant_groups.flat_map { |group| group.evidence_sources.to_a }.find { |source| source.article_id == article.id }
    end

    def planned_jobs
      action_set = actions
      jobs = action_set.fetch(:fetch).map { |url| "fetch_evidence #{url}" }
      jobs.concat(action_set.fetch(:reconcile).map { |slug| "reconcile #{slug}" })
      jobs.concat(action_set.fetch(:enrich).map { |slug| "refresh_enrichment #{slug}" })
    end

    # This is the complete execution contract.  SubmitGroup compares this list
    # after taking every submission/domain lock, then performs no new planning.
    def actions
      @actions ||= {
        reset: reset_urls,
        fetch: @preflight.evidence_urls.zip(@preflight.evidence).select { |url, article|
          source = source_for(article)
          source.nil? || reset_urls.include?(url) || (source.pending? && source.fetch_retry_due_at.nil?) || EvidenceFetchLease.delivery_eligible?(source, at: @decision_at)
        }.map(&:first).sort,
        reconcile: reconciliation_slugs,
        enrich: projected_enrichment,
        destroy: @preflight.relevant_groups.select { |group|
          GroupSubmissionPreflight.disposable_group?(group) && group.main_investigation_id != @main.id
        }.map(&:id).sort,
        reuse: @preflight.evidence.compact.map(&:normalized_url).sort
      }
    end

    def reconciliation_slugs
      @preflight.members.compact.select { |member| member.completed? && ReconciliationLease.current_revision_delivery_eligible?(member, at: @decision_at || Time.current) }.map(&:slug).sort
    end

    def projected_enrichment
      group = @preflight.relevant_groups.find { |candidate| candidate.main_investigation_id == @main.id }
      EnrichmentLease.proposed_group_delivery_eligible?(group: group, proposed_members: @preflight.members.compact, eligible_at: @decision_at) ? [ @main.slug ] : []
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def planned_intents
      planned_jobs.map(&:dup).sort
    end

    # Include every mutable input that can affect repair delivery or enrichment.
    def planning_input
      { members: @preflight.members.compact.sort_by(&:id).map { |member|
          article = member.root_article
          { id: member.id, status: member.status, group_id: member.investigation_group_id,
            revisions: member.attributes.slice("evidence_revision_assessed", "reconciliation_revision", "reconciliation_attempts"),
            root: article && article.attributes.slice("fetch_status", "rejection_reason", "content_generation", "content_fingerprint"),
            summary: member.pipeline_steps.where(name: "generate_summary").order(:id).pluck(:status, :finished_at),
            analysis: member.attributes.slice("analysis_completed_at", "headline_bait_score", "llm_summary", "contextual_gaps", "coordinated_narrative", "honest_headline", "event_context"),
            claims: member.claim_assessments.includes(:claim).order(:id).map { |assessment| [ assessment.claim.canonical_text, assessment.verdict, assessment.confidence_score ] },
            children: member.auto_submitted_children.order(:id).map { |child| [ child.id, child.status, child.root_article&.fetch_status, child.root_article&.rejection_reason ] } }
        }, groups: @preflight.relevant_groups.sort_by(&:id).map { |group|
          { id: group.id, fields: group.attributes.slice("evidence_revision", "enrichment_applied_fingerprint", "enrichment_attempts", "enrichment_retry_due_at", "enrichment_delivery_token", "enrichment_delivery_expires_at"),
            evidence: group.evidence_sources.order(:id).map { |source| source.attributes.slice(*GroupSubmissionPreflight::SOURCE_FIELDS) } }
        } }
    end
  end
end
