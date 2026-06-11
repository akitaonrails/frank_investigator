module Investigations
  # After cross-referencing completes, auto-submit related articles found by
  # the coordinated narrative detector so the cross-investigation composite
  # builds out naturally without manual URL submissions.
  #
  # Each child is tagged with auto_submitted_from_id so its analysis can
  # feed back into the parent's event_context and honest_headline via
  # RefreshParentEnrichmentJob once the child completes.
  #
  # Cap is configurable via FRANK_INVESTIGATOR_AUTO_SUBMIT_MAX (default 5).
  # Candidates are deduplicated by host so each submission is a different
  # outlet — submitting five articles from the same publisher would not
  # widen the editorial picture.
  class AutoSubmitRelatedJob < ApplicationJob
    queue_as :default

    DEFAULT_MAX_AUTO_SUBMISSIONS = 5

    def self.max_auto_submissions
      ENV.fetch("FRANK_INVESTIGATOR_AUTO_SUBMIT_MAX", DEFAULT_MAX_AUTO_SUBMISSIONS).to_i
    end

    def perform(investigation_id)
      investigation = Investigation.find(investigation_id)
      return unless investigation.completed?

      coverage = Array(investigation.coordinated_narrative&.dig("similar_coverage"))
      return if coverage.empty?

      cap = self.class.max_auto_submissions
      return if cap <= 0

      submitted = 0
      seen_hosts = Set.new
      # Reserve a slot for the parent's own host so we never pick a sibling
      # from the same outlet — that wouldn't add a new editorial voice.
      seen_hosts << investigation.root_article&.host&.downcase if investigation.root_article&.host.present?

      coverage.each do |item|
        break if submitted >= cap

        url = item["url"].to_s
        next if url.blank?

        normalized = begin
          Investigations::UrlNormalizer.call(url)
        rescue StandardError
          next
        end

        host = host_for(normalized)
        next if host.blank? || seen_hosts.include?(host)

        next if Investigation.exists?(normalized_url: normalized)

        begin
          Investigations::UrlClassifier.call(normalized)
        rescue Investigations::UrlClassifier::RejectedUrlError
          next
        end

        Investigations::EnsureStarted.call(
          submitted_url: normalized,
          auto_submitted_from: investigation.id
        )
        Rails.logger.info("[AutoSubmit] Auto-submitted #{normalized.truncate(60)} from investigation #{investigation.slug}")
        seen_hosts << host
        submitted += 1
      rescue StandardError => e
        Rails.logger.warn("[AutoSubmit] Failed to submit #{url&.truncate(60)}: #{e.message}")
      end
    end

    private

    def host_for(url)
      URI.parse(url).host.to_s.downcase.presence
    rescue URI::InvalidURIError
      nil
    end
  end
end
