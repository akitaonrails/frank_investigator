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
        extract_from_text(CASE_NUMBER_REGEX)
      end

      def docket_reference
        extract_from_text(DOCKET_REGEX)
      end
    end
  end
end
