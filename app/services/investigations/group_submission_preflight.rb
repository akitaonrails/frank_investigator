require "digest"

module Investigations
  # Read-only normalization and ownership check for every explicit group change.
  # Keeping this object free of writes makes it safe for operator dry-runs.
  class GroupSubmissionPreflight
    MAX_NEWS_URLS = 10
    MAX_EVIDENCE_URLS = 20
    MAX_URL_LENGTH = 2048
    MAX_RAW_ENTRIES = 100
    class ConflictError < StandardError; end

    attr_reader :main_url, :news_urls, :evidence_urls, :members, :evidence, :fingerprint, :warnings, :before, :after, :relevant_groups

    GROUP_OPERATIONAL_FIELDS = %w[
      main_investigation_id evidence_revision enriched_revision enrichment_fingerprint
      enrichment_token enrichment_target_fingerprint enrichment_applied_fingerprint
      enrichment_lease_expires_at enrichment_attempts enrichment_error enrichment_retry_due_at
      enrichment_delivery_token enrichment_delivery_expires_at
    ].freeze
    MEMBER_GROUP_FIELDS = %w[
      investigation_group_id group_membership_kind evidence_revision_assessed reconciliation_token
      reconciliation_revision reconciliation_lease_expires_at reconciliation_attempts
      evidence_reconciliation_attempts_revision evidence_reconciliation_retry_due_at
      evidence_reconciliation_retry_delivery_token evidence_reconciliation_retry_delivery_expires_at
      reconciliation_error reconciliation_enrichment_pending_revision
      reconciliation_enrichment_delivered_revision reconciliation_enrichment_delivery_token
      reconciliation_enrichment_delivery_expires_at
    ].freeze
    SOURCE_FIELDS = %w[
      id investigation_group_id article_id submitted_url status content_fingerprint fetch_token
      fetch_lease_expires_at fetch_retry_due_at fetch_delivery_token fetch_delivery_expires_at
      fetch_attempts_generation attempts_count last_error_class last_error_message terminal_at ready_at
    ].freeze

    def self.call(**kwargs) = new(**kwargs).call

    def self.disposable_group?(group)
      members = group.investigations.to_a
      return false unless members.one?
      member = members.first
      return false unless member && group.main_investigation_id == member.id && member.group_membership_kind_manual? && group.evidence_sources.none?
      return false unless member.auto_submitted_from_id.nil? && member.auto_submitted_children.none?
      group.attributes.slice("evidence_revision", "enriched_revision", "enrichment_attempts").values.all? { |v| v.to_i.zero? } &&
        group.attributes.slice("enrichment_token", "enrichment_error", "enrichment_fingerprint", "enrichment_target_fingerprint", "enrichment_applied_fingerprint", "enrichment_retry_due_at", "enrichment_lease_expires_at", "enrichment_delivery_token", "enrichment_delivery_expires_at").values.all?(&:blank?)
    end

    def initialize(main_url:, news_urls: [], evidence_urls: [], repair: false)
      raise ArgumentError, "main_url must be a URL string" unless main_url.is_a?(String)
      @main_url = main_url
      @news_urls = urls_from(news_urls, "news_urls")
      @evidence_urls = urls_from(evidence_urls, "evidence_urls")
      raise ArgumentError, "too many submitted URLs" if @news_urls.size + @evidence_urls.size > MAX_RAW_ENTRIES
      @repair = repair
      @warnings = []
    end

    def call
      # Classification intentionally happens before any database lookup.  This
      # is the submission boundary for *all* URL roles.
      @main_url = normalize!(main_url)
      @news_urls = news_urls.map { |url| normalize!(url) }.uniq.reject { |url| url == main_url }
      @evidence_urls = evidence_urls.map { |url| normalize!(url) }.uniq
      raise ArgumentError, "too many news URLs (max #{MAX_NEWS_URLS})" if news_urls.size > MAX_NEWS_URLS
      raise ArgumentError, "too many evidence URLs (max #{MAX_EVIDENCE_URLS})" if evidence_urls.size > MAX_EVIDENCE_URLS
      raise ConflictError, "a URL cannot be both news and evidence" if (([ main_url ] + news_urls) & evidence_urls).any?

      @members = desired_urls.map { |url| Investigation.find_by(normalized_url: url) }
      @evidence = evidence_urls.map { |url| Article.find_by(normalized_url: url) }
      if @repair && members.any?(&:nil?)
        raise ConflictError, "repair only reuses existing investigations: #{desired_urls.zip(members).select { |_url, record| record.nil? }.map(&:first).join(', ')}"
      end
      @relevant_groups = groups_for_members(members.compact)
      validate_ownership!
      @before = state_for(members.compact)
      @after = { owner_url: main_url, members: desired_urls.map { |url| [ url, "manual" ] }, evidence: evidence_urls }
      @fingerprint = Digest::SHA256.hexdigest(snapshot_payload.to_json)
      freeze_exposed_state!
    end

    def grouped? = news_urls.any? || evidence_urls.any?
    def repair? = @repair
    def desired_urls = [ main_url ] + news_urls
    def snapshot_valid? = self.class.call(main_url:, news_urls:, evidence_urls:, repair: @repair).fingerprint == fingerprint

    private

    def freeze_exposed_state!
      [ @main_url, @fingerprint ].each(&:freeze)
      [ @news_urls, @evidence_urls, @members, @evidence, @relevant_groups, @warnings, @before, @after ].each { |value| deep_freeze(value) }
      freeze
    end

    # Records themselves remain mutable Active Record instances; only the
    # preflight snapshot's exposed containers/scalars are immutable.
    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      when String then value.freeze
      end
      value.freeze unless value.is_a?(ActiveRecord::Base)
    end

    def urls_from(value, name)
      return [] if value.nil?
      flatten(value, name).flat_map { |item| item.split(/\r?\n/) }.map(&:strip).reject(&:blank?)
    end

    def flatten(value, name)
      case value
      when String then [ value ]
      when Array then value.flat_map { |item| flatten(item, name) }
      else raise ArgumentError, "#{name} must be an array or newline-delimited text"
      end
    end

    def normalize!(url)
      raise ArgumentError, "URL too long (max #{MAX_URL_LENGTH})" if url.length > MAX_URL_LENGTH
      normalized = UrlNormalizer.call(url)
      UrlClassifier.call(normalized)
      normalized
    end

    def validate_ownership!
      desired = desired_urls
      relevant_groups.each do |group|
        current = group.investigations.order(:normalized_url).pluck(:normalized_url, :group_membership_kind)
        evidence_urls_current = group.evidence_sources.joins(:article).order("articles.normalized_url").pluck("articles.normalized_url")
        exact = group.main_investigation_id == members.first&.id && current == desired.sort.map { |url| [ url, "manual" ] } && evidence_urls_current == evidence_urls.sort
        next if exact || disposable?(group)
        raise ConflictError, "investigation group #{group.id} has unexpected members or evidence"
      end
    end

    def disposable?(group)
      self.class.disposable_group?(group)
    end

    def groups_for_members(records)
      membership = records.map(&:investigation_group).compact
      owned = records.map(&:owned_group).compact
      (membership + owned).uniq.sort_by(&:id)
    end

    def state_for(records)
      records.map do |record|
        group = record.investigation_group
        { url: record.normalized_url, id: record.id, role: record.group_membership_kind, group_id: group&.id,
          owner_id: group&.main_investigation_id, auto_parent_id: record.auto_submitted_from_id,
          auto_child_ids: record.auto_submitted_children.order(:id).pluck(:id),
          group_state: record.attributes.slice(*MEMBER_GROUP_FIELDS) }
      end.sort_by { |entry| entry[:url] }
    end

    def snapshot_payload
      { urls: desired_urls, evidence: evidence_urls, before:, after:,
        groups: relevant_groups.map { |group| group_snapshot(group) },
        desired_articles: evidence.compact.sort_by(&:id).map { |article| { id: article.id, normalized_url: article.normalized_url, content_generation: article.content_generation } } }
    end

    def group_snapshot(group)
      { id: group.id,
        operational: group.attributes.slice(*GROUP_OPERATIONAL_FIELDS),
        members: group.investigations.order(:id).map { |member|
          { id: member.id, normalized_url: member.normalized_url, auto_parent_id: member.auto_submitted_from_id,
            auto_child_ids: member.auto_submitted_children.order(:id).pluck(:id),
            group_state: member.attributes.slice(*MEMBER_GROUP_FIELDS) }
        },
        evidence: group.evidence_sources.includes(:article).order(:id).map { |source|
          source.attributes.slice(*SOURCE_FIELDS).merge("article_normalized_url" => source.article.normalized_url,
            "article_content_generation" => source.article.content_generation)
        } }
    end
  end
end
