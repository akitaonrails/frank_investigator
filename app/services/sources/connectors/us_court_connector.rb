module Sources
  module Connectors
    class UsCourtConnector < BaseConnector
      CASE_NUMBER_REGEX = /\b\d{1,2}[:-]\d{2}[:-](?:cv|cr|mc|mj|bk|ap|br|gj|mp|po|sw|at|md)\b[^\n]{0,30}/i
      DOCKET_REGEX = /\b(?:No\.|Case\s+No\.|Docket\s+No\.)\s*[^\n]{1,50}/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :court_record,
          authority_tier: :primary,
          authority_score: 0.97,
          metadata_json: {
            "connector" => "us_court",
            "site_name" => generic_site_name,
            "source_role" => "authenticated_legal_text",
            "case_number" => case_number,
            "docket_reference" => docket_reference
          }.compact
        )
      end

      private

      def case_number
        text = [@title, page_text_sample].join("\n")
        text.match(CASE_NUMBER_REGEX)&.to_s&.squish
      end

      def docket_reference
        text = [@title, page_text_sample].join("\n")
        text.match(DOCKET_REGEX)&.to_s&.squish
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 5000].to_s
      end
    end
  end
end
