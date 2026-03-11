module Parsing
  class MainContentExtractor
    Result = Struct.new(:title, :body_text, :excerpt, :main_content_path, :links, keyword_init: true)

    BLOCKED_SELECTORS = [
      "script", "style", "noscript", "iframe", "form", "header", "footer", "nav", "aside", "svg",
      ".ad-container", ".sidebar", ".trending", ".most-read", ".related-articles",
      ".comments", "#comments", "#disqus_thread", ".social-share",
      "[role='complementary']", "[role='navigation']"
    ].join(",").freeze

    CONTENT_SELECTORS = [
      "article",
      "main article",
      "[itemprop='articleBody']",
      ".article-body",
      ".post-content",
      ".entry-content",
      ".story-body",
      ".materia-conteudo",
      ".content-text",
      ".text",
      "[data-block='articleBody']",
      "main",
      "body"
    ].freeze

    NOISE_CLASS_PATTERN = /related|trending|popular|sidebar|widget|share|comment/i

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

      Result.new(
        title: @document.at("title")&.text.to_s.squish,
        body_text:,
        excerpt: body_text.truncate(280),
        main_content_path: selector,
        links: extract_links(node)
      )
    end

    private

    def best_content_node
      candidates = CONTENT_SELECTORS.filter_map do |selector|
        node = @document.at_css(selector)
        next unless node

        strip_noise(node)
        text = extract_body_text(node)
        next if text.blank?

        [node, selector, text.length]
      end

      match = candidates.max_by { |(_, _, length)| length } || [@document.at_css("body") || @document.root, "body", 0]
      node, selector, length = match

      # Density-based fallback when selector-based extraction yields too little
      if selector != "body" && length < 200
        density_text = TextDensityAnalyzer.extract(@document)
        if density_text && density_text.length > length
          return [@document.at_css("body") || @document.root, "body(density)"]
        end
      end

      [node, selector]
    end

    def extract_body_text(node)
      paragraphs = node.css("p, h2, h3, li").map { |element| element.text.squish }.reject(&:blank?)
      text = paragraphs.join("\n\n")
      text.presence || node.text.squish
    end

    def strip_noise(node)
      node.css("div, section, ul, ol, aside").each do |child|
        total_text = child.text.to_s.length
        next if total_text < 20

        link_text = child.css("a").sum { |a| a.text.to_s.length }
        link_ratio = total_text > 0 ? link_text.to_f / total_text : 0

        css_classes = child["class"].to_s
        if link_ratio > 0.5 && css_classes.match?(NOISE_CLASS_PATTERN)
          child.remove
        end
      end
    end

    def extract_links(node)
      node.css("a[href]").each_with_index.filter_map do |anchor, index|
        href = normalize_link(anchor["href"])
        next unless href

        {
          href:,
          anchor_text: anchor.text.squish,
          context_excerpt: anchor.parent&.text.to_s.squish.truncate(240),
          position: index
        }
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
