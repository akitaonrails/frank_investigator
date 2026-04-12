require "digest"

module Investigations
  class EmbeddingDocument
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
        subjects_line,
        lead_section,
        claims_section,
        gaps_section
      ].compact.join("\n").strip
    end

    def digest
      Digest::SHA256.hexdigest(call)
    end

    private

    def title_line
      return if signals.title.blank?

      "title: #{signals.title}"
    end

    def host_line
      return if signals.host.blank?

      "host: #{signals.host}"
    end

    def subjects_line
      subjects = signals.primary_subjects.to_a.sort
      return if subjects.empty?

      "subjects: #{subjects.join(', ')}"
    end

    def lead_section
      return if signals.lead_text.blank?

      "lead: #{signals.lead_text}"
    end

    def claims_section
      claims = signals.central_claim_records.map do |record|
        claim = record.claim
        assessment = @investigation.claim_assessments.find { |item| item.claim_id == claim.id }
        verdict = assessment&.verdict || "pending"
        "#{claim.canonical_text} [#{verdict}]"
      end

      if claims.empty?
        claims = signals.central_claim_texts.map { |text| "#{text} [pending]" }
      end
      return if claims.empty?

      "claims:\n- #{claims.join("\n- ")}"
    end

    def gaps_section
      gaps = signals.relevant_gap_questions
      return if gaps.empty?

      "gaps:\n- #{gaps.join("\n- ")}"
    end

    def signals
      @signals ||= IdentitySignals.new(@investigation)
    end
  end
end
