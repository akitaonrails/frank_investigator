module Investigations
  class EmbeddingIndexer
    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      return unless SqliteVec.ready?

      record = @investigation.investigation_embedding || @investigation.build_investigation_embedding
      document = EmbeddingDocument.new(investigation: @investigation)
      digest = document.digest
      return record if current?(record, digest)

      record.assign_attributes(
        status: :pending,
        model_id: model_id,
        dimensions: dimensions,
        content_digest: digest,
        error_class: nil,
        error_message: nil
      )

      embedding = RubyLLM.embed(
        document.call,
        model: model_id,
        provider: provider.presence,
        dimensions:
      )
      vector = Array(embedding.vectors).map(&:to_f)
      validate_dimensions!(vector)

      SqliteVec.insert!(investigation_id: @investigation.id, vector:)

      record.status = :indexed
      record.embedding_json = JSON.generate(vector)
      record.indexed_at = Time.current
      record.save!
      record
    rescue StandardError => e
      record ||= @investigation.investigation_embedding || @investigation.build_investigation_embedding
      record.assign_attributes(
        status: :failed,
        model_id: model_id,
        dimensions: dimensions,
        content_digest: digest || record.content_digest || "unavailable",
        embedding_json: record.embedding_json,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(500)
      )
      record.save!(validate: false)
      Rails.logger.warn("[EmbeddingIndexer] Failed for #{@investigation.slug}: #{e.class}: #{e.message}")
      nil
    end

    private

    def current?(record, digest)
      record.indexed? &&
        record.content_digest == digest &&
        record.model_id == model_id &&
        record.dimensions == dimensions &&
        record.embedding_json.present?
    end

    def validate_dimensions!(vector)
      return if vector.size == dimensions

      raise ArgumentError, "Expected #{dimensions} embedding dimensions, got #{vector.size}"
    end

    def provider
      Rails.configuration.x.frank_investigator.embedding_provider
    end

    def model_id
      Rails.configuration.x.frank_investigator.embedding_model
    end

    def dimensions
      Rails.configuration.x.frank_investigator.embedding_dimensions
    end
  end
end
