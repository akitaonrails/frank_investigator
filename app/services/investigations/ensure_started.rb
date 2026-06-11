module Investigations
  class EnsureStarted
    def self.call(submitted_url:, auto_submitted_from: nil)
      new(submitted_url:, auto_submitted_from:).call
    end

    def initialize(submitted_url:, auto_submitted_from: nil)
      @submitted_url = submitted_url
      @auto_submitted_from_id = auto_submitted_from.respond_to?(:id) ? auto_submitted_from.id : auto_submitted_from
    end

    def call
      normalized_url = UrlNormalizer.call(@submitted_url)

      investigation = ApplicationRecord.transaction do
        article = find_or_create_article!(normalized_url)

        Investigation.find_or_create_by!(normalized_url:) do |record|
          record.submitted_url = @submitted_url
          record.root_article = article
          record.auto_submitted_from_id = @auto_submitted_from_id
        end.tap do |record|
          if record.root_article_id.nil? || record.submitted_url != @submitted_url
            record.update!(submitted_url: @submitted_url, root_article: article)
          end
          # Backfill the lineage on a previously-known investigation that was
          # later discovered as a child via auto-submission. Only set, never
          # overwrite an existing parent — first parent wins.
          if @auto_submitted_from_id && record.auto_submitted_from_id.nil?
            record.update!(auto_submitted_from_id: @auto_submitted_from_id)
          end
        end
      end

      if investigation.queued? && investigation.pipeline_steps.none?
        Investigations::KickoffJob.perform_later(investigation.id)
      end
      investigation
    end

    private

    def find_or_create_article!(normalized_url)
      Article.find_or_create_by!(normalized_url:) do |record|
        source_metadata = Sources::AuthorityClassifier.call(url: normalized_url, host: URI.parse(normalized_url).host)
        record.url = normalized_url
        record.host = URI.parse(normalized_url).host
        record.source_kind = source_metadata.source_kind
        record.authority_tier = source_metadata.authority_tier
        record.authority_score = source_metadata.authority_score
        record.independence_group = source_metadata.independence_group
        record.source_role = source_metadata.source_role || :unknown
      end
    rescue ActiveRecord::RecordNotUnique
      Article.find_by!(normalized_url:)
    end
  end
end
