module Investigations
  # Runs after generate_summary. Searches for related investigations
  # about the same event and enriches all of them with composite context.
  # No cascading — this job does NOT trigger re-analysis on siblings.
  class CrossReferenceJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)
      return unless @investigation.completed?

      Investigations::EmbeddingIndexer.call(investigation: @investigation)
      Analyzers::CrossInvestigationEnricher.call(investigation: @investigation)
      Rails.logger.info("[CrossReference] Enriched investigation #{@investigation.slug}")

      # Auto-submit related articles for full investigation
      Investigations::AutoSubmitRelatedJob.perform_later(@investigation.id)
    rescue StandardError => e
      # Non-fatal — cross-referencing is enrichment, not a required step
      Rails.logger.warn("[CrossReference] Failed for #{@investigation.slug}: #{e.message}")
    end
  end
end
