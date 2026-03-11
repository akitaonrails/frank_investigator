module Sources
  module Connectors
    class BrazilLegislativeConnector < BaseConnector
      BILL_REGEX = /\b(PL|PEC|MPV|PDC|PLP|PLS|PLC|PLN|MSG|RIC|REQ|INC|SUG)\s*n?[ºo°.]?\s*\d+\/\d{2,4}\b/i
      COMMISSION_REGEX = /\b(CCJ|CCJC|CAE|CAS|CMA|CCT|CTFC|CFT|CSSF|CDH|CE|CI|CRA|CRE|CDR|plenario|plenário|Mesa Diretora)\b/i

      # Law number patterns
      LAW_REGEX = /\b(Lei Complementar|Lei Delegada|Emenda Constitucional|Decreto Legislativo|Decreto-Lei|Decreto|Lei)\b\s*(?:n.?\s*)?\d+[^\n]{0,20}/i

      # Voting patterns
      VOTE_REGEX = /\b(aprovad[oa]|rejeitad[oa]|votação|votacao|turno|destaque|obstrução|obstrucao)\b[^\n]{0,60}/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :legislative_record,
          authority_tier: :primary,
          authority_score: 0.97,
          metadata_json: {
            "connector" => "brazil_legislative",
            "site_name" => generic_site_name,
            "source_role" => "authenticated_legal_text",
            "chamber" => chamber,
            "bill_reference" => bill_reference,
            "law_reference" => law_reference,
            "commission" => commission,
            "vote_status" => vote_status
          }.compact
        )
      end

      private

      def chamber
        return "camara" if @host.match?(/camara\.leg\.br/i)
        return "senado" if @host.match?(/senado\.leg\.br/i)
        nil
      end

      def bill_reference
        text = [@title, page_text_sample].join("\n")
        text.match(BILL_REGEX)&.to_s&.squish
      end

      def law_reference
        text = [@title, page_text_sample].join("\n")
        text.match(LAW_REGEX)&.to_s&.squish
      end

      def commission
        text = [@title, page_text_sample].join("\n")
        text.match(COMMISSION_REGEX)&.to_s&.squish
      end

      def vote_status
        page_text_sample.match(VOTE_REGEX)&.to_s&.squish
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 5000].to_s
      end
    end
  end
end
