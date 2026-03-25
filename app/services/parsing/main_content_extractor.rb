module Parsing
  class MainContentExtractor
    Result = Struct.new(:title, :body_text, :excerpt, :main_content_path, :links, keyword_init: true)

    BLOCKED_SELECTORS = [
      # Structural noise
      "script", "style", "noscript", "iframe", "form", "header", "footer", "nav", "aside", "svg",
      "figcaption", "figure picture",
      "[role='complementary']", "[role='navigation']", "[role='banner']", "[role='contentinfo']",
      "[aria-hidden='true']",

      # Ads and tracking
      ".ad-container", ".ad-wrapper", ".ads", ".advertisement", ".dfp-ad", ".google-ad",
      "[id^='google_ads']", "[class*='ad-slot']", "[class*='adunit']", "[data-ad]",

      # Sidebars and widgets
      ".sidebar", ".widget", ".aside-content", ".lateral",

      # Related content and navigation
      ".trending", ".most-read", ".related-articles", ".related-content", ".read-more",
      ".mais-lidas", ".leia-tambem", ".leia-mais", ".veja-tambem", ".saiba-mais",
      ".recommended", ".suggestions", ".carousel",
      "[class*='related']", "[class*='trending']",

      # Social and engagement
      ".social-share", ".share-buttons", ".social-buttons", ".social-links",
      ".compartilhar", ".compartilhe",
      "[class*='share-']", "[class*='social-']",

      # Comments
      ".comments", "#comments", "#disqus_thread", ".comment-section",
      ".comentarios", "#comentarios",

      # Newsletter and subscription
      ".newsletter", ".newsletter-signup", ".newsletter-form",
      ".paywall", ".paywall-gate", ".premium-content", ".subscription-required",
      "[data-paywall]", "[data-gated]",

      # Brazilian-specific noise
      ".tags-list", ".tag-list", ".editoria-list",
      ".author-info", ".autor-info", ".byline-block",
      ".breadcrumb", ".breadcrumbs",
      ".print-only", ".no-print",

      # Video players and embeds
      ".video-player", ".jwplayer", "[class*='video-']", ".vjs-control-bar",
      ".media-player", "[data-player]",

      # Privacy/cookie notices
      ".lgpd", ".cookie-banner", ".cookie-notice", "[class*='cookie']",
      "[class*='consent']", "[class*='lgpd']", "[class*='gdpr']"
    ].join(",").freeze

    CONTENT_SELECTORS = [
      "[itemprop='articleBody']",
      "article .article-body",
      "article .post-content",
      "article .entry-content",
      ".c-news__body",
      ".materia-conteudo",
      ".corpo-materia",
      ".corpo-texto",
      ".noticia-corpo",
      ".story-body",
      ".content-text__container",
      "[data-block='articleBody']",
      "article",
      "main article",
      ".article-body",
      ".post-content",
      ".entry-content",
      ".content-text",
      ".text",
      "main",
      "body"
    ].freeze

    NOISE_CLASS_PATTERN = /related|trending|popular|sidebar|widget|share|comment|newsletter|tags|breadcrumb|autor|author|byline|leia|mais-lida|recomend|sugest|carousel|social|anuncio/i

    def self.call(html:, url:)
      new(html:, url:).call
    end

    def initialize(html:, url:)
      @document = Nokogiri::HTML(html)
      @url = url
    end

    def call
      @document.css(BLOCKED_SELECTORS).remove
      node, selector = best_content_node
      body_text = extract_body_text(node)
      excerpt = extract_excerpt(node, body_text)

      Result.new(
        title: @document.at("title")&.text.to_s.squish,
        body_text:,
        excerpt:,
        main_content_path: selector,
        links: extract_links(node)
      )
    end

    private

    # Build excerpt from the first real paragraph — not the raw body_text which
    # may include navigation noise when extraction falls back to <body>.
    # Requires 80+ chars, low link density, and no noise patterns.
    def extract_excerpt(node, body_text)
      node.css("p").each do |p|
        text = p.text.squish
        next if text.length < 80
        next if text.match?(AD_MARKER_PATTERN) || text.match?(SHARE_TEXT_PATTERN) || text.match?(SECTION_HEADER_PATTERN)
        # Skip paragraphs that are mostly links (navigation)
        link_len = p.css("a").sum { |a| a.text.to_s.length }
        next if text.length > 0 && link_len.to_f / text.length > 0.5
        # Skip paragraphs that end with a question mark and have no period — likely prompts/CTAs
        next if text.end_with?("?") && !text.include?(".")
        return text.truncate(280)
      end
      body_text.truncate(280)
    end

    def best_content_node
      candidates = CONTENT_SELECTORS.filter_map do |selector|
        node = @document.at_css(selector)
        next unless node

        strip_noise(node)
        text = extract_body_text(node)
        next if text.blank?

        [ node, selector, text.length ]
      end

      match = candidates.max_by { |(_, _, length)| length } || [ @document.at_css("body") || @document.root, "body", 0 ]
      node, selector, length = match

      # Density-based fallback when selector-based extraction yields too little
      if selector != "body" && length < 200
        density_text = TextDensityAnalyzer.extract(@document)
        if density_text && density_text.length > length
          return [ @document.at_css("body") || @document.root, "body(density)" ]
        end
      end

      [ node, selector ]
    end

    AD_MARKER_PATTERN = /\A\s*(?:Publicidade|Propaganda|Anúncio|Advertisement|Sponsored|Ad)\s*\z/i

    SHARE_TEXT_PATTERN = /\A\s*(?:copiar\s+link|copy\s+link|compartilhar|share\s+this)\s*\z/i

    # Short lines that look like tags, labels, or author names (no sentence structure)
    # Matches: single words, proper noun pairs, tag-like phrases without periods/verbs
    TAG_LINE_PATTERN = /\A[\p{L}\p{N}]+(?:\s+[\p{L}\p{N}]+){0,4}\z/

    # Section headers like "Tópicos relacionados", "Leia também", etc.
    SECTION_HEADER_PATTERN = /\A(?:Tópicos?\s+relacionados?|Tags?|Leia\s+(?:também|mais)|Veja\s+(?:também|mais)|Related\s+(?:topics?|articles?)|Continua\s+depois\s+da\s+publicidade)\z/i

    def extract_body_text(node)
      paragraphs = node.css("p, h2, h3, li")
        .map { |element| element.text.squish }
        .reject { |t| t.blank? || t.match?(AD_MARKER_PATTERN) || t.match?(SHARE_TEXT_PATTERN) || t.match?(SECTION_HEADER_PATTERN) }
      text = paragraphs.join("\n\n")
      text = strip_trailing_tags(text) if text.present?
      text = strip_leading_byline(text) if text.present?
      text.presence || node.text.squish
    end

    # Pattern for inline attribution stuck to end of paragraph: "...text.Name Name, title"
    TRAILING_ATTRIBUTION_PATTERN = /[.!?]\p{Lu}\p{Ll}+(?:\s+\p{L}+){1,5},\s+\p{Ll}[\p{L}\s\/]+\z/

    def strip_trailing_tags(text)
      lines = text.split("\n\n")
      # Remove trailing short lines that look like tag labels or bylines (no sentence structure)
      while lines.size > 1 && lines.last.length < 60 && lines.last.match?(TAG_LINE_PATTERN)
        lines.pop
      end
      # Strip inline attribution concatenated to last paragraph (e.g. "...no varejo.Matheus Dias, economista do FGV/Ibre")
      if lines.last&.match?(TRAILING_ATTRIBUTION_PATTERN)
        lines[-1] = lines.last.sub(/(?<=[.!?])\p{Lu}\p{Ll}+(?:\s+\p{L}+){1,5},\s+\p{Ll}[\p{L}\s\/]+\z/, "")
      end
      lines.join("\n\n")
    end

    def strip_leading_byline(text)
      lines = text.split("\n\n")
      # Remove leading lines that look like bylines: "Name Name" followed by "date time"
      while lines.size > 1 && lines.first.length < 80
        first = lines.first
        break unless first.match?(/\A\p{Lu}\p{Ll}+(?:\s+\p{L}+){1,3}\z/) || # "Élida Oliveira"
                     first.match?(/\A\d{1,2}\/\d{1,2}\/\d{2,4}\s/) ||                                  # "02/01/2026 05h00..."
                     first.match?(/\A(?:Atualizado|Updated)\b/i)                                          # "Atualizado 3 meses..."
        lines.shift
      end
      lines.join("\n\n")
    end

    def strip_noise(node)
      node.css("div, section, ul, ol, aside, span").each do |child|
        total_text = child.text.to_s.length
        next if total_text < 20

        css_classes = (child["class"].to_s + " " + child["id"].to_s).downcase
        link_text = child.css("a").sum { |a| a.text.to_s.length }
        link_ratio = total_text > 0 ? link_text.to_f / total_text : 0

        # Remove blocks with noise class names and high link density
        if link_ratio > 0.5 && css_classes.match?(NOISE_CLASS_PATTERN)
          child.remove
          next
        end

        # Remove any block with a noise class even without high link density
        if css_classes.match?(NOISE_CLASS_PATTERN) && total_text < 500
          child.remove
          next
        end

        # Remove blocks that are > 70% links (navigation, regardless of class)
        if link_ratio > 0.7 && total_text > 50
          child.remove
        end
      end
    end

    # Only extract links that are inline citations within editorial text.
    #
    # Two-layer filter:
    # 1. Only look inside content-bearing elements (p, h2, h3, li) — same set as
    #    extract_body_text — to exclude links in <div>, <nav>, <ul> chrome.
    # 2. Require the parent element to contain enough non-link prose to be
    #    considered editorial. Navigation chrome uses <p> tags as wrappers for
    #    single link labels ("Newsletters", "Edição Impressa", topic tags).
    #    Editorial citations sit inside sentences where link text is a small
    #    fraction of the surrounding prose.
    #
    # Threshold: parent must have at least 40 chars of non-link text.
    # This keeps "...cites the <a>budget document</a>..." (plenty of prose)
    # and rejects "<p><a>Newsletters</a></p>" (zero non-link text).
    MIN_NONLINK_TEXT = 40

    def extract_links(node)
      index = 0
      node.css("p, h2, h3, li").flat_map do |content_el|
        el_text = content_el.text.to_s.squish
        links = content_el.css("a[href]")
        next [] if links.empty?

        link_text_length = links.sum { |a| a.text.to_s.length }
        nonlink_text = el_text.length - link_text_length
        next [] if nonlink_text < MIN_NONLINK_TEXT

        links.filter_map do |anchor|
          href = normalize_link(anchor["href"])
          next unless href

          pos = index
          index += 1
          {
            href:,
            anchor_text: anchor.text.squish,
            context_excerpt: el_text.truncate(240),
            position: pos
          }
        end
      end
    end

    def normalize_link(href)
      return nil if href.blank? || href.start_with?("#", "mailto:", "tel:", "javascript:")

      Investigations::UrlNormalizer.call(URI.join(@url, href).to_s)
    rescue Investigations::UrlNormalizer::InvalidUrlError, URI::InvalidURIError
      nil
    end
  end
end
