module Investigations
  class EnsureStarted
    def self.call(submitted_url:)
      new(submitted_url:).call
    end

    def initialize(submitted_url:)
      @submitted_url = submitted_url
    end

    def call
      normalized_url = UrlNormalizer.call(@submitted_url)

      investigation = ApplicationRecord.transaction do
        article = find_or_create_article!(normalized_url)

        Investigation.find_or_create_by!(normalized_url:) do |record|
          record.submitted_url = @submitted_url
          record.root_article = article
        end.tap do |record|
          if record.root_article_id.nil? || record.submitted_url != @submitted_url
            record.update!(submitted_url: @submitted_url, root_article: article)
          end
        end
      end

      Investigations::KickoffJob.perform_later(investigation.id)
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
