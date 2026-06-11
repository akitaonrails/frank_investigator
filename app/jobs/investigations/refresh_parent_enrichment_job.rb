module Investigations
  # When an auto-submitted child investigation finishes, feed its analysis
  # back into the parent investigation's enrichment-stage outputs:
  #
  #   1. CrossInvestigationEnricher re-computes the parent's event_context
  #      (composite timeline + critical omissions) now that the child's
  #      event-context data exists in the corpus.
  #   2. HonestHeadlineGenerator regenerates the parent's honest_headline
  #      using the fresh event_context, which the prompt treats as the
  #      single MOST IMPORTANT input.
  #
  # The parent's claim-level analyses are not touched — only the synthesis
  # layer that depends on cross-investigation context changes.
  #
  # Race safety: parents are locked pessimistically so multiple child
  # completions for the same parent serialize without losing writes.
  # Idempotency: last_enrichment_refresh_at is stamped after every successful
  # refresh; subsequent calls with no newer children become no-ops.
  class RefreshParentEnrichmentJob < ApplicationJob
    queue_as :default

    def perform(parent_id)
      parent = Investigation.find_by(id: parent_id)
      return unless parent&.completed?

      Investigation.transaction do
        parent.lock!

        latest_child_at = parent.auto_submitted_children
                                .where(status: "completed")
                                .maximum(:analysis_completed_at)
        return if latest_child_at.nil?

        last_refresh = parent.last_enrichment_refresh_at
        return if last_refresh.present? && last_refresh >= latest_child_at

        Analyzers::CrossInvestigationEnricher.call(investigation: parent)

        honest = Analyzers::HonestHeadlineGenerator.call(investigation: parent)
        updates = { last_enrichment_refresh_at: Time.current }
        updates[:honest_headline] = honest if honest.present?
        parent.update_columns(updates)
      end

      Rails.logger.info("[RefreshParent] Refreshed enrichment for parent #{parent.slug}")
    rescue StandardError => e
      Rails.logger.warn("[RefreshParent] Failed for parent_id=#{parent_id}: #{e.class}: #{e.message}")
    end
  end
end
