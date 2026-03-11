module Sources
  module Connectors
    class UsStatisticsConnector < BaseConnector
      FRED_SERIES_REGEX = %r{/series/([A-Z][A-Z0-9]{2,20})\b}i
      RELEASE_REGEX = /\b(CPI|Payroll|Unemployment|GDP|PCE|Employment Situation|Consumer Price Index|Producer Price Index|Job Openings|JOLTS|ACS|American Community Survey)\b/i

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :government_record,
          authority_tier: :primary,
          authority_score: authority_score,
          metadata_json: {
            "connector" => "us_statistics",
            "site_name" => generic_site_name,
            "source_role" => "neutral_statistics",
            "data_agency" => data_agency,
            "series_id" => series_id,
            "release_name" => release_name
          }.compact
        )
      end

      private

      def authority_score
        return 0.97 if bls_host? || fed_host?
        0.96
      end

      def data_agency
        return "BLS" if bls_host?
        return "Census" if census_host?
        return "Federal Reserve" if fed_host?
        return "FRED" if fred_host?
        generic_site_name
      end

      def series_id
        return nil unless fred_host?
        @url.match(FRED_SERIES_REGEX)&.captures&.first
      end

      def release_name
        text = [@title, page_text_sample].join("\n")
        text.match(RELEASE_REGEX)&.to_s
      end

      def page_text_sample
        @page_text_sample ||= @document.text[0, 5000].to_s
      end

      def bls_host?
        @host.match?(/bls\.gov\z/i)
      end

      def census_host?
        @host.match?(/census\.gov\z/i)
      end

      def fed_host?
        @host.match?(/federalreserve\.gov\z/i)
      end

      def fred_host?
        @host.match?(/stlouisfed\.org\z/i)
      end
    end
  end
end
