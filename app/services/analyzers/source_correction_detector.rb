module Analyzers
  # Detects when evidence articles have been modified since they were used
  # in a claim assessment. If an article's body text has changed (correction,
  # retraction, update), the assessments that relied on it may be stale.
  #
  # This defends against "zombie evidence" — where our verdict is based on
  # content that the source itself has since corrected or retracted.
  class SourceCorrectionDetector
    Result = Struct.new(:corrected_articles, :affected_assessments, keyword_init: true)

    def self.call
      new.call
    end

    def call
      corrected = detect_body_changes
      affected = flag_affected_assessments(corrected)

      Result.new(
        corrected_articles: corrected.size,
        affected_assessments: affected
      )
    end

    private

    def detect_body_changes
      changed = []

      # Find articles that have a stored body_fingerprint and current body_text
      Article.where.not(body_fingerprint: nil)
        .where.not(body_text: nil)
        .where(body_changed_since_assessment: false)
        .find_each do |article|
          current_hash = Digest::SHA256.hexdigest(article.body_text)
          if current_hash != article.body_fingerprint
            article.update_columns(body_changed_since_assessment: true)
            changed << article
          end
        end

      changed
    end

    def flag_affected_assessments(changed_articles)
      return 0 if changed_articles.empty?

      changed_urls = changed_articles.map(&:normalized_url)
      count = 0

      # Find assessments with evidence items pointing to changed articles
      ClaimAssessment.joins(:evidence_items)
        .where(evidence_items: { source_url: changed_urls })
        .where.not(verdict: "pending")
        .where(stale_at: nil)
        .distinct
        .find_each do |assessment|
          assessment.update!(
            stale_at: Time.current,
            staleness_reason: "source_corrected"
          )
          count += 1
        end

      count
    end
  end
end
