require "digest"

module Investigations
  class EmbeddingDocument
    MAX_BODY_CHARS = 1500
    MAX_CLAIMS = 8
    MAX_GAPS = 6

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      [
        title_line,
        host_line,
        claims_section,
        gaps_section,
        body_section
      ].compact.join("\n").strip
    end

    def digest
      Digest::SHA256.hexdigest(call)
    end

    private

    def title_line
      return if root_article.blank? || root_article.title.blank?

      "title: #{root_article.title}"
    end

    def host_line
      return if root_article.blank? || root_article.host.blank?

      "host: #{root_article.host}"
    end

    def claims_section
      claims = @investigation.claim_assessments.includes(:claim).map do |assessment|
        claim = assessment.claim
        next if claim.blank?

        "#{claim.canonical_text} [#{assessment.verdict}]"
      end.compact.first(MAX_CLAIMS)
      return if claims.empty?

      "claims:\n- #{claims.join("\n- ")}"
    end

    def gaps_section
      gaps = Array(@investigation.contextual_gaps&.dig("gaps")).filter_map { |gap| gap["question"].presence }.first(MAX_GAPS)
      return if gaps.empty?

      "gaps:\n- #{gaps.join("\n- ")}"
    end

    def body_section
      return if root_article.blank? || root_article.body_text.blank?

      cleaned = root_article.body_text.squish.truncate(MAX_BODY_CHARS)
      return if cleaned.blank?

      "body: #{cleaned}"
    end

    def root_article
      @investigation.root_article
    end
  end
end
