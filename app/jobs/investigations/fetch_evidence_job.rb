module Investigations
  class FetchEvidenceJob < ApplicationJob
    queue_as :fetch

    def perform(evidence_source_id)
      source = InvestigationGroupEvidenceSource.includes(:article, :investigation_group).find(evidence_source_id)
      token = EvidenceFetchLease.claim!(source)
      return unless token

      article = source.article
      snapshot = fetcher.call(article.normalized_url)
      staged = Articles::PersistFetchedContent.prepare(article:, html: snapshot.html, fetched_title: snapshot.title, current_depth: 0, evidence: true)

      changed = publish!(source, token, staged)
      enqueue_reconciliation(source.investigation_group) if changed
    rescue Fetchers::ChromiumFetcher::FetchError => error
      EvidenceFetchLease.fail_transient!(source, token, error) if source && token
    rescue Articles::PersistFetchedContent::StaleGeneration
      # Another owner published a newer Article generation. Discard this staged
      # result; the durable source remains recoverable without stale writes.
      EvidenceFetchLease.fail_transient!(source, token, Fetchers::ChromiumFetcher::FetchError.new("article generation changed")) if source && token
    rescue StandardError => error
      Rails.logger.warn("[FetchEvidence] #{error.class}: #{error.message}")
      raise
    end

    private

    def fetcher
      Rails.application.config.x.frank_investigator.fetcher_class.constantize
    end

    def enqueue_reconciliation(group)
      group.investigations.group_membership_kind_manual.find_each do |investigation|
        ReconcileGroupEvidenceJob.perform_later(investigation.id)
      end
    end

    # This is deliberately the only persistence point after the browser work.
    # The source row is locked first; a worker whose lease was taken over cannot
    # write either the shared Article or the group's revision.
    def publish!(source, token, staged)
      changed = false
      ApplicationRecord.transaction do
        source.lock!
        return false unless EvidenceFetchLease.active?(source, token)
        group = InvestigationGroup.lock.find(source.investigation_group_id)
        article = source.article.lock!
        # The source token only protects this evidence source. Article content is
        # shared with root/linked fetches and other groups, so generation is the
        # second mandatory CAS fence for both terminal outcomes.
        raise Articles::PersistFetchedContent::StaleGeneration unless article.content_generation == staged.content_generation
        if staged.rejected?
          source.update!(status: :rejected, terminal_at: Time.current, fetch_token: nil, fetch_lease_expires_at: nil,
            fetch_retry_due_at: nil, fetch_delivery_token: nil, fetch_delivery_expires_at: nil,
            last_error_class: nil, last_error_message: staged.rejection_reason)
          return false
        end

        fingerprint = staged.assessment_fingerprint
        changed = source.content_fingerprint != fingerprint
        Articles::PersistFetchedContent.publish!(article:, staged:)
        source.update!(status: :ready, ready_at: Time.current, content_fingerprint: fingerprint,
          fetch_token: nil, fetch_lease_expires_at: nil, fetch_retry_due_at: nil, fetch_delivery_token: nil,
          fetch_delivery_expires_at: nil, terminal_at: nil, last_error_class: nil, last_error_message: nil)
        InvestigationGroup.where(id: group.id).update_all("evidence_revision = evidence_revision + 1") if changed
      end
      changed
    end
  end
end
