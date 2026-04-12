module Investigations
  class VectorCandidateRetriever
    DEFAULT_LIMIT = 25
    MAX_DISTANCE = 0.45

    def self.call(investigation:, limit: DEFAULT_LIMIT)
      new(investigation:, limit:).call
    end

    def initialize(investigation:, limit:)
      @investigation = investigation
      @limit = limit
    end

    def call
      return [] unless SqliteVec.ready?

      source_embedding = Investigations::EmbeddingIndexer.call(investigation: @investigation)
      return [] unless source_embedding&.indexed?

      candidate_rows = SqliteVec.nearest_neighbors(
        vector: vector_for(@investigation.id),
        limit: @limit + 1,
        exclude_ids: [ @investigation.id ]
      ).select { |row| row["distance"].to_f <= MAX_DISTANCE }
      return [] if candidate_rows.empty?

      indexed_ids = InvestigationEmbedding.indexed.where(investigation_id: candidate_rows.map { |row| row["investigation_id"] })
        .pluck(:investigation_id)
        .to_set
      ordered_ids = candidate_rows.map { |row| row["investigation_id"] }
        .select { |id| indexed_ids.include?(id) && id != @investigation.id }
      investigations_by_id = Investigation.where(id: ordered_ids)
        .includes(:root_article, claim_assessments: :claim)
        .index_by(&:id)

      ordered_ids.filter_map { |id| investigations_by_id[id] }
    rescue StandardError => e
      Rails.logger.warn("[VectorCandidateRetriever] Failed for #{@investigation.slug}: #{e.class}: #{e.message}")
      []
    end

    private

    def vector_for(investigation_id)
      json = InvestigationEmbedding.indexed.find_by!(investigation_id:)&.embedding_json
      JSON.parse(json)
    end
  end
end
