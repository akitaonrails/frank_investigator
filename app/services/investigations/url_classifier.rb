require "uri"

module Investigations
  class UrlClassifier
    class RejectedUrlError < StandardError
      attr_reader :rejection_key

      def initialize(rejection_key, message)
        @rejection_key = rejection_key
        super(message)
      end
    end

    SOCIAL_MEDIA_HOSTS = %w[
      twitter.com x.com facebook.com fb.com instagram.com
      tiktok.com youtube.com youtu.be reddit.com
      linkedin.com threads.net mastodon.social
      t.me telegram.org discord.com discord.gg
      pinterest.com tumblr.com
    ].freeze

    ECOMMERCE_HOSTS = %w[
      amazon.com amazon.com.br amazon.co.uk amazon.de amazon.fr
      ebay.com aliexpress.com shopee.com.br shopee.com
      mercadolivre.com.br mercadolibre.com
      magazineluiza.com.br magalu.com.br
      americanas.com.br submarino.com.br
      casasbahia.com.br extra.com.br
      shein.com temu.com wish.com etsy.com
      walmart.com walmart.com.br target.com
    ].freeze

    SEARCH_ENGINE_HOSTS = %w[
      google.com google.com.br bing.com yahoo.com
      duckduckgo.com baidu.com yandex.com yandex.ru
    ].freeze

    ECOMMERCE_PATH_PATTERNS = %r{
      /(?:product|produto|item|dp|gp/product|shop|cart|checkout|basket|wishlist|buy|order)/
    }ix

    def self.call(url)
      new(url).call
    end

    def initialize(url)
      @url = url
      @uri = URI.parse(url)
      @host = @uri.host&.downcase&.sub(/\Awww\./, "")
      @path = @uri.path.to_s
      @query = @uri.query.to_s
    end

    NON_ARTICLE_HOSTS = %w[
      falabr.cgu.gov.br acesso.gov.br
      api.whatsapp.com web.whatsapp.com wa.me
    ].freeze

    NON_ARTICLE_HOST_PATTERNS = [
      /\Asidra\./i,
      /\Alps\./i,
      /\Astatic\./i,
      /\Aofertas\./i,
      /\Aassinatura\./i,
      /\Aassine\./i,
      /\An?\.?comentarios?\./i
    ].freeze

    def call
      reject_social_media!
      reject_ecommerce!
      reject_search_engine!
      reject_non_content!
      reject_non_article_host!
      reject_bare_homepage!
      true
    end

    private

    def reject_social_media!
      return unless host_matches?(SOCIAL_MEDIA_HOSTS)

      raise RejectedUrlError.new(:social_media, I18n.t("investigations.url_rejected.social_media"))
    end

    def reject_ecommerce!
      return unless host_matches?(ECOMMERCE_HOSTS) || ecommerce_path?

      raise RejectedUrlError.new(:ecommerce, I18n.t("investigations.url_rejected.ecommerce"))
    end

    def reject_search_engine!
      return unless host_matches?(SEARCH_ENGINE_HOSTS)

      raise RejectedUrlError.new(:search_engine, I18n.t("investigations.url_rejected.search_engine"))
    end

    def reject_non_content!
      # File downloads that aren't documents we can parse
      non_content_extensions = /\.(?:zip|rar|tar|gz|7z|exe|dmg|apk|ipa|mp3|mp4|avi|mkv|mov|wav|flac|iso|img|bin)\z/i
      if @path.match?(non_content_extensions)
        raise RejectedUrlError.new(:non_content, I18n.t("investigations.url_rejected.non_content"))
      end
    end

    def reject_non_article_host!
      return unless @host

      if NON_ARTICLE_HOSTS.any? { |h| @host == h || @host.end_with?(".#{h}") }
        raise RejectedUrlError.new(:non_article_host, I18n.t("investigations.url_rejected.non_article_host"))
      end

      if NON_ARTICLE_HOST_PATTERNS.any? { |p| @host.match?(p) }
        raise RejectedUrlError.new(:non_article_host, I18n.t("investigations.url_rejected.non_article_host"))
      end
    end

    def reject_bare_homepage!
      clean_path = @path.chomp("/")
      return if clean_path.blank? && @query.present?

      segments = clean_path.split("/").reject(&:blank?)

      if segments.empty?
        raise RejectedUrlError.new(:index_page, I18n.t("investigations.url_rejected.index_page"))
      end
    end

    def ecommerce_path?
      @path.match?(ECOMMERCE_PATH_PATTERNS)
    end

    def host_matches?(list)
      return false unless @host

      list.any? { |h| @host == h || @host.end_with?(".#{h}") }
    end
  end
end
