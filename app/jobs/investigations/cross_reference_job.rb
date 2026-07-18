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
      # Grouped members and auto-parents have a durable generation protocol;
      # this job must never bypass its CAS publication.
      if @investigation.investigation_group_id.present? || @investigation.auto_submitted_children.where(status: "completed").exists?
        RefreshParentEnrichmentJob.perform_later(@investigation.investigation_group&.main_investigation_id || @investigation.id)
      # Standalone investigations own their local, non-shared context.
      elsif (context = Analyzers::CrossInvestigationEnricher.call(investigation: @investigation))
        @investigation.update_column(:event_context, context)
      end
      Rails.logger.info("[CrossReference] Enriched investigation #{@investigation.slug}")

      # Auto-submit related articles for full investigation
      Investigations::AutoSubmitRelatedJob.perform_later(@investigation.id)
    rescue StandardError => e
      # Non-fatal — cross-referencing is enrichment, not a required step
      Rails.logger.warn("[CrossReference] Failed for #{@investigation.slug}: #{e.message}")
    end
  end
end
