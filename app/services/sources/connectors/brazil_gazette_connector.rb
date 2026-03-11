module Sources
  module Connectors
    class BrazilGazetteConnector < BaseConnector
      # DOU section patterns
      SECTION_REGEX = /\b(Se[cç][aã]o\s*[123]|Edi[cç][aã]o\s+(?:Extra|Suplementar))\b/i

      # Legal act patterns found in official gazettes
      ACT_REGEX = /\b(Decreto|Lei|Medida Provis[oó]ria|Portaria|Resolu[cç][aã]o|Instru[cç][aã]o Normativa|Ato Declarat[oó]rio|Despacho|Aviso|Edital|Circular)\b\s*(?:n[ºo°.]?\s*)?\d+[^\n]{0,40}/i

      # Publication date in gazette format
      GAZETTE_DATE_REGEX = /\b(\d{1,2})\s+de\s+(janeiro|fevereiro|mar[cç]o|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)\s+de\s+(\d{4})\b/i

      def extract
        Result.new(
          published_at: gazette_published_at || generic_published_at,
          source_kind: :government_record,
          authority_tier: :primary,
          authority_score: 0.99,
          metadata_json: {
            "connector" => "brazil_gazette",
            "site_name" => generic_site_name,
            "source_role" => "authenticated_legal_text",
            "section" => section,
            "act_reference" => act_reference,
            "gazette_scope" => gazette_scope
          }.compact
        )
      end

      private

      def section
        page_text_sample.match(SECTION_REGEX)&.to_s&.squish
      end

      def act_reference
        text = [@title, page_text_sample].join("\n")
        text.match(ACT_REGEX)&.to_s&.squish
      end

      def gazette_scope
        return "federal" if @host.match?(/imprensanacional|in\.gov\.br|dou/i)
        return "state" if @host.match?(/diariooficial|doe\.|ioerj|imesp/i)
        return "municipal" if @host.match?(/dom\.|diariomunicipal/i)
        "unknown"
      end

      def gazette_published_at
        match = page_text_sample.match(GAZETTE_DATE_REGEX)
        return nil unless match

        months = {
          "janeiro" => 1, "fevereiro" => 2, "março" => 3, "marco" => 3,
          "abril" => 4, "maio" => 5, "junho" => 6, "julho" => 7,
          "agosto" => 8, "setembro" => 9, "outubro" => 10,
          "novembro" => 11, "dezembro" => 12
        }

        day = match[1].to_i
        month = months[match[2].downcase.tr("ç", "c")]
        year = match[3].to_i
        Time.zone.local(year, month, day) rescue nil
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 8000].to_s
      end
    end
  end
end
