module Sources
  module Connectors
    class BrazilLegislativeConnector < BaseConnector
      BILL_REGEX = /\b(PL|PEC|MPV|PDC|PLP)\s*\d+\/\d{2,4}\b/i
      COMMISSION_REGEX = /\b(CCJ|CAE|CAS|CMA|CCT|CTFC|plenario|plenário)\b/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :legislative_record,
          authority_tier: :primary,
          authority_score: 0.97,
          metadata_json: {
            "connector" => "brazil_legislative",
            "site_name" => generic_site_name,
            "bill_reference" => bill_reference,
            "commission" => commission
          }.compact
        )
      end

      private

      def bill_reference
        [@title, @document.text].join("\n").match(BILL_REGEX)&.to_s&.squish
      end

      def commission
        [@title, @document.text].join("\n").match(COMMISSION_REGEX)&.to_s&.squish
      end
    end
  end
end
