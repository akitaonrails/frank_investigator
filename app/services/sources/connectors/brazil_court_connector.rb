module Sources
  module Connectors
    class BrazilCourtConnector < BaseConnector
      CASE_REGEX = /\b\d{4,7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}\b/
      MINISTER_REGEX = /\b(ministro|ministra|relator|relatora)\s+[A-ZÀ-Ý][A-Za-zÀ-ÿ]+/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :court_record,
          authority_tier: :primary,
          authority_score: 0.97,
          metadata_json: {
            "connector" => "brazil_court",
            "site_name" => generic_site_name,
            "case_number" => case_number,
            "rapporteur" => rapporteur
          }.compact
        )
      end

      private

      def case_number
        [@title, @document.text].join("\n").match(CASE_REGEX)&.to_s
      end

      def rapporteur
        [@title, @document.text].join("\n").match(MINISTER_REGEX)&.to_s&.squish
      end
    end
  end
end
