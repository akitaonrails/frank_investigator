module Sources
  module Connectors
    class BaseConnector
      Result = Struct.new(:published_at, :metadata_json, :source_kind, :authority_tier, :authority_score, keyword_init: true)

      PAGE_TEXT_LIMIT = 5000

      def initialize(url:, host:, title:, html:)
        @url = url.to_s
        @host = host.to_s
        @title = title.to_s
        @document = Nokogiri::HTML(html)
      end

      private

      def page_text_sample
        @page_text_sample ||= @document.text[0, self.class::PAGE_TEXT_LIMIT].to_s
      end

      def extract_from_text(regex)
        text = [@title, page_text_sample].join("\n")
        text.match(regex)&.to_s&.squish
      end

      def meta_value(*selectors)
        selectors.each do |selector|
          value = @document.at_css(selector)&.[]("content") || @document.at_css(selector)&.text
          return value.to_s.squish if value.present?
        end

        nil
      end

      def parsed_time(*values)
        values.compact.each do |value|
          return Time.zone.parse(value.to_s) if value.present?
        rescue ArgumentError, TypeError
          next
        end

        nil
      end

      def generic_published_at
        parsed_time(
          meta_value("meta[property='article:published_time']"),
          meta_value("meta[name='pubdate']"),
          meta_value("meta[name='publish-date']"),
          @document.at_css("time")&.[]("datetime"),
          @document.at_css("time")&.text
        )
      end

      def generic_site_name
        meta_value("meta[property='og:site_name']")
      end
    end
  end
end
