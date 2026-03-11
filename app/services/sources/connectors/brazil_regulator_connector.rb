module Sources
  module Connectors
    class BrazilRegulatorConnector < BaseConnector
      # Regulatory document patterns
      RESOLUTION_REGEX = /\b(Resolu[cç][aã]o|Instru[cç][aã]o Normativa|Portaria|Circular|Nota T[eé]cnica|Comunicado)\b\s*(?:n[ºo°.]?\s*)?\d+[^\n]{0,40}/i

      # CNPJ pattern
      CNPJ_REGEX = /\b\d{2}\.\d{3}\.\d{3}\/\d{4}-\d{2}\b/

      AGENCY_MAP = {
        "anvisa.gov.br" => { name: "Anvisa", domain: "health_regulatory" },
        "bcb.gov.br" => { name: "Banco Central do Brasil", domain: "monetary_financial" },
        "gov.br/receitafederal" => { name: "Receita Federal", domain: "tax_fiscal" },
        "receita.fazenda.gov.br" => { name: "Receita Federal", domain: "tax_fiscal" },
        "tcu.gov.br" => { name: "TCU", domain: "oversight_audit" },
        "cgu.gov.br" => { name: "CGU", domain: "oversight_audit" },
        "anatel.gov.br" => { name: "Anatel", domain: "telecom_regulatory" },
        "aneel.gov.br" => { name: "ANEEL", domain: "energy_regulatory" },
        "ans.gov.br" => { name: "ANS", domain: "health_insurance_regulatory" },
        "anp.gov.br" => { name: "ANP", domain: "petroleum_regulatory" },
        "antaq.gov.br" => { name: "ANTAQ", domain: "waterway_regulatory" },
        "antt.gov.br" => { name: "ANTT", domain: "transport_regulatory" },
        "anac.gov.br" => { name: "ANAC", domain: "aviation_regulatory" },
        "ana.gov.br" => { name: "ANA", domain: "water_regulatory" },
        "ancine.gov.br" => { name: "ANCINE", domain: "audiovisual_regulatory" },
        "cade.gov.br" => { name: "CADE", domain: "competition_regulatory" },
        "susep.gov.br" => { name: "SUSEP", domain: "insurance_regulatory" },
        "previc.gov.br" => { name: "PREVIC", domain: "pension_regulatory" }
      }.freeze

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: source_kind,
          authority_tier: :primary,
          authority_score: authority_score,
          metadata_json: {
            "connector" => "brazil_regulator",
            "site_name" => generic_site_name,
            "source_role" => source_role,
            "agency" => agency_info[:name],
            "regulatory_domain" => agency_info[:domain],
            "resolution_reference" => resolution_reference,
            "cnpj" => cnpj
          }.compact
        )
      end

      private

      def source_kind
        return :government_record if oversight_agency?
        :government_record
      end

      def source_role
        return "oversight" if oversight_agency?
        return "neutral_statistics" if monetary_agency?
        "authenticated_legal_text"
      end

      def authority_score
        return 0.97 if oversight_agency? || monetary_agency?
        0.95
      end

      def oversight_agency?
        %w[tcu.gov.br cgu.gov.br].any? { |h| @host.include?(h) }
      end

      def monetary_agency?
        @host.include?("bcb.gov.br")
      end

      def agency_info
        @agency_info ||= begin
          match = AGENCY_MAP.find { |pattern, _| @host.include?(pattern) || @url.include?(pattern) }
          match ? match[1] : { name: generic_site_name, domain: "government" }
        end
      end

      def resolution_reference
        text = [@title, page_text_sample].join("\n")
        text.match(RESOLUTION_REGEX)&.to_s&.squish
      end

      def cnpj
        page_text_sample.match(CNPJ_REGEX)&.to_s
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 5000].to_s
      end
    end
  end
end
