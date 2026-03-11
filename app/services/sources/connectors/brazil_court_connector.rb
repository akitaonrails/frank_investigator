module Sources
  module Connectors
    class BrazilCourtConnector < BaseConnector
      PAGE_TEXT_LIMIT = 8000

      # CNJ unified numbering: NNNNNNN-DD.AAAA.J.TR.OOOO
      CASE_REGEX = /\b\d{4,7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}\b/
      MINISTER_REGEX = /\b(ministro|ministra|relator|relatora|desembargador|desembargadora)\s+[A-ZÀ-Ý][A-Za-zÀ-ÿ\s]{2,40}/i

      # Action type patterns (ADI, ADPF, RE, HC, MS, etc.)
      ACTION_TYPE_REGEX = /\b(ADI|ADPF|ADC|ADO|RE|AI|HC|MS|MI|RCL|ACO|Pet|Inq|AP|RHC|RMS|SS|SL|STA|STP|IF|AR|ED|AgR)\b\s*(?:n[ºo°.]?\s*)?\d+/i

      # Court identification
      COURT_MAP = {
        "stf.jus.br" => { name: "STF", level: "supreme" },
        "stj.jus.br" => { name: "STJ", level: "superior" },
        "tse.jus.br" => { name: "TSE", level: "superior_electoral" },
        "tst.jus.br" => { name: "TST", level: "superior_labor" },
        "stm.jus.br" => { name: "STM", level: "superior_military" }
      }.freeze

      # Ruling/decision patterns
      RULING_REGEX = /\b(acord[aã]o|decis[aã]o monocr[aá]tica|liminar|tutela|senten[cç]a|despacho|voto)\b/i

      # Publication date in legal format
      LEGAL_DATE_REGEX = /\b(DJe|DJ|DOU|DOE)\s*(?:de\s+)?(\d{1,2}[\/.-]\d{1,2}[\/.-]\d{2,4})/i

      def extract
        Result.new(
          published_at: legal_published_at || generic_published_at,
          source_kind: :court_record,
          authority_tier: :primary,
          authority_score: 0.97,
          metadata_json: {
            "connector" => "brazil_court",
            "site_name" => generic_site_name,
            "source_role" => "authenticated_legal_text",
            "court" => court_info[:name],
            "court_level" => court_info[:level],
            "case_number" => case_number,
            "action_type" => action_type,
            "rapporteur" => rapporteur,
            "ruling_type" => ruling_type,
            "publication_reference" => publication_reference
          }.compact
        )
      end

      private

      def court_info
        @court_info ||= begin
          match = COURT_MAP.find { |pattern, _| @host.include?(pattern) }
          if match
            match[1]
          elsif (trf_match = @host.match(/trf(\d)/))
            { name: "TRF#{trf_match[1]}", level: "federal_regional" }
          elsif (tj_match = @host.match(/tj([a-z]{2})/))
            { name: "TJ#{tj_match[1].upcase}", level: "state" }
          else
            { name: generic_site_name, level: "unknown" }
          end
        end
      end

      def case_number
        extract_from_text(CASE_REGEX)
      end

      def action_type
        extract_from_text(ACTION_TYPE_REGEX)
      end

      def rapporteur
        extract_from_text(MINISTER_REGEX)
      end

      def ruling_type
        page_text_sample.match(RULING_REGEX)&.to_s&.squish&.downcase
      end

      def publication_reference
        page_text_sample.match(LEGAL_DATE_REGEX)&.to_s&.squish
      end

      def legal_published_at
        match = page_text_sample.match(LEGAL_DATE_REGEX)
        return nil unless match

        parsed_time(match[2])
      end

    end
  end
end
