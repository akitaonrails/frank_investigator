module Sources
  module Connectors
    class UsSecFilingConnector < BaseConnector
      FORM_REGEX = /\b(10-K|10-Q|8-K|20-F|6-K|DEF\s*14A|S-1|S-3|424B|13F|SC\s*13[DG]|13D|13G|DEFA14A|ARS|N-CSR)\b/i
      CIK_REGEX = /\bCIK[=:\s]*(\d{7,10})\b/i
      ACCESSION_REGEX = /\b(\d{10}-\d{2}-\d{6})\b/

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :company_filing,
          authority_tier: :primary,
          authority_score: 0.98,
          metadata_json: {
            "connector" => "us_sec_filing",
            "site_name" => generic_site_name,
            "source_role" => "authenticated_legal_text",
            "filing_type" => filing_type,
            "cik" => cik,
            "accession_number" => accession_number
          }.compact
        )
      end

      private

      def filing_type
        text = [@title, @url, page_text_sample].join("\n")
        text.match(FORM_REGEX)&.to_s&.upcase
      end

      def cik
        text = [@url, page_text_sample].join("\n")
        text.match(CIK_REGEX)&.captures&.first
      end

      def accession_number
        text = [@url, page_text_sample].join("\n")
        text.match(ACCESSION_REGEX)&.to_s
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 5000].to_s
      end
    end
  end
end
