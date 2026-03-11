module Sources
  module Connectors
    class BrazilMarketFilingConnector < BaseConnector
      TICKER_REGEX = /\b[A-Z]{4}\d{1,2}\b/
      FILING_REGEX = /\b(fato relevante|formulario de referencia|formulário de referência|comunicado ao mercado|release de resultados)\b/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :company_filing,
          authority_tier: :primary,
          authority_score: 0.92,
          metadata_json: {
            "connector" => "brazil_market_filing",
            "site_name" => generic_site_name,
            "ticker" => ticker,
            "filing_type" => filing_type
          }.compact
        )
      end

      private

      def ticker
        [@title, @document.text].join("\n").match(TICKER_REGEX)&.to_s
      end

      def filing_type
        [@title, @document.text].join("\n").match(FILING_REGEX)&.to_s&.squish
      end
    end
  end
end
