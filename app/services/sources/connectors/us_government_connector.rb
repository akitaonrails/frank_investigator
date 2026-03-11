module Sources
  module Connectors
    class UsGovernmentConnector < BaseConnector
      DOCUMENT_REGEX = /\b(Executive Order|Public Law|H\.R\.|S\.\s*\d|Rule|Notice|Proposed Rule|Final Rule|Presidential Memorandum|Presidential Proclamation|Federal Register)\b[^\n]{0,60}/i
      FR_CITATION_REGEX = /\d+\s+FR\s+\d+/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: source_kind,
          authority_tier: :primary,
          authority_score: authority_score,
          metadata_json: {
            "connector" => "us_government",
            "site_name" => generic_site_name,
            "source_role" => source_role,
            "document_reference" => document_reference,
            "fr_citation" => fr_citation
          }.compact
        )
      end

      private

      def source_kind
        return :legislative_record if congress_host?
        :government_record
      end

      def source_role
        return "authenticated_legal_text" if govinfo_host? || congress_host? || federal_register_host?
        return "neutral_statistics" if statistics_host?
        return "oversight" if oversight_host?
        return "official_position" if whitehouse_host?
        "authenticated_legal_text"
      end

      def authority_score
        return 0.72 if whitehouse_host?
        return 0.99 if govinfo_host?
        return 0.98 if congress_host?
        0.97
      end

      def document_reference
        text = [@title, page_text_sample].join("\n")
        text.match(DOCUMENT_REGEX)&.to_s&.squish
      end

      def fr_citation
        text = [@title, page_text_sample].join("\n")
        text.match(FR_CITATION_REGEX)&.to_s&.squish
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 5000].to_s
      end

      def govinfo_host?
        @host.match?(/govinfo\.gov\z/i)
      end

      def congress_host?
        @host.match?(/congress\.gov\z/i)
      end

      def federal_register_host?
        @host.match?(/federalregister\.gov\z/i)
      end

      def statistics_host?
        @host.match?(/\b(bls\.gov|census\.gov|federalreserve\.gov|stlouisfed\.org)\z/i)
      end

      def oversight_host?
        @host.match?(/\b(gao\.gov|cbo\.gov)\z/i)
      end

      def whitehouse_host?
        @host.match?(/whitehouse\.gov\z/i)
      end
    end
  end
end
