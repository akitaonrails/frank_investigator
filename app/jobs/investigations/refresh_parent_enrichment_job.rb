module Investigations
  # Computes enrichment outside transactions, then publishes only if the
  # lease's token and deterministic input generation still match.
  class RefreshParentEnrichmentJob < ApplicationJob
    queue_as :default

    def perform(parent_id)
      parent = Investigation.find_by(id: parent_id)
      return unless parent&.completed?

      parent.investigation_group ? refresh_group(parent.investigation_group) : refresh_legacy(parent)
    end

    private

    def refresh_group(group)
      claim = EnrichmentLease.group_claim(group)
      return unless claim

      context = Analyzers::CrossInvestigationEnricher.call(investigation: claim.members.first, investigations: claim.members)
      raise "No cross-investigation context produced" unless context
      headlines = claim.manual_members.to_h do |member|
        [ member.id, Analyzers::HonestHeadlineGenerator.call(investigation: member, event_context: context) ]
      end
      result = EnrichmentLease.group_publish(group, claim, context, headlines)
      self.class.perform_later(group.main_investigation_id) if result == :stale
    rescue StandardError => e
      EnrichmentLease.group_fail(group, claim, e) if claim
      Rails.logger.warn("[RefreshParent] group failed for #{group.id}: #{e.class}: #{e.message}")
    end

    def refresh_legacy(parent)
      claim = EnrichmentLease.legacy_claim(parent)
      return unless claim

      # The exact parent/child snapshot is part of the claim. Never permit
      # global heuristic candidates to enter an un-fingerprinted generation.
      context = Analyzers::CrossInvestigationEnricher.call(investigation: parent, investigations: claim.members)
      headline = Analyzers::HonestHeadlineGenerator.call(investigation: parent, event_context: context)
      result = EnrichmentLease.legacy_publish(parent, claim, context, headline)
      self.class.perform_later(parent.id) if result == :stale
    rescue StandardError => e
      EnrichmentLease.legacy_fail(parent, claim, e) if claim
      Rails.logger.warn("[RefreshParent] legacy failed for #{parent.id}: #{e.class}: #{e.message}")
    end
  end
end
