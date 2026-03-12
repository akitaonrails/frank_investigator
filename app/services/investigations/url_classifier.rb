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

    # Paths that look like index/category pages rather than articles
    INDEX_PATH_PATTERN = %r{\A/(?:[a-z0-9_-]+/?)?(?:\?.*)?(?:#.*)?\z}i

    # Paths that contain an article-like identifier (slug, numeric ID, date components)
    ARTICLE_SIGNALS = [
      /\d{4}\/\d{2}/,                    # date component: 2025/03
      /\/\d{4}-\d{2}-\d{2}\b/,           # ISO date: /2025-03-11
      /\/[a-z0-9-]{15,}\b/i,             # long slug: /article-title-goes-here
      /\.\w{3,5}\z/,                     # file extension: .ghtml, .html, .shtml, .asp
      /\/\d{3,}\b/,                      # numeric ID >= 3 digits: /12345
      /[?&]id=\d+/,                      # query param ID: ?id=123
      /[?&](?:noticia|materia|artigo)=/i, # Portuguese article params
      /[?&](?:article|story|post)=/i,     # English article params
      /\/(?:noticia|materia|artigo)\//i,  # Portuguese article path segments
      /\/(?:article|story|post|news)\//i, # English article path segments
    ].freeze

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

    def call
      reject_social_media!
      reject_ecommerce!
      reject_search_engine!
      reject_non_content!
      reject_index_page!
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

    def reject_index_page!
      # Root path with no meaningful path segments
      clean_path = @path.chomp("/")
      return if clean_path.blank? && @query.present? # allow root with query params (API-style)

      segments = clean_path.split("/").reject(&:blank?)

      if segments.empty?
        raise RejectedUrlError.new(:index_page, I18n.t("investigations.url_rejected.index_page"))
      end

      # Single short segment with no article signals = likely a category/section page
      if segments.size == 1 && !has_article_signals?
        raise RejectedUrlError.new(:section_page, I18n.t("investigations.url_rejected.section_page"))
      end

      # Two segments but both are short category-like words (e.g., /economia/mercado)
      if segments.size == 2 && segments.all? { |s| s.length < 12 && s.match?(/\A[a-z-]+\z/i) } && !has_article_signals?
        raise RejectedUrlError.new(:section_page, I18n.t("investigations.url_rejected.section_page"))
      end
    end

    def has_article_signals?
      path_and_query = "#{@path}?#{@query}"
      ARTICLE_SIGNALS.any? { |pattern| path_and_query.match?(pattern) }
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
