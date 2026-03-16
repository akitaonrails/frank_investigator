require "nokogiri"
require "json"

module Parsing
  class ArticleDetector
    Result = Struct.new(:article, :score, :signals, keyword_init: true)

    ARTICLE_JSONLD_TYPES = %w[
      NewsArticle Article BlogPosting ReportageNewsArticle Report
      TechArticle ScholarlyArticle AnalysisNewsArticle OpinionNewsArticle
      ReviewNewsArticle LiveBlogPosting
    ].freeze

    THRESHOLD = 0.30

    def self.call(html:)
      new(html).call
    end

    def initialize(html)
      @html = html
      @doc = Nokogiri::HTML(html)
    end

    def call
      signals = {}

      signals[:jsonld_article_type] = detect_jsonld_article_type
      signals[:og_type_article] = detect_og_type_article
      signals[:published_timestamp] = detect_published_timestamp
      signals[:author_metadata] = detect_author_metadata
      signals[:semantic_article_tag] = detect_semantic_article_tag
      signals[:text_structure] = detect_text_structure
      signals[:low_link_density] = detect_low_link_density
      signals[:h1_present] = detect_h1_present

      weights = {
        jsonld_article_type: 0.30,
        og_type_article: 0.15,
        published_timestamp: 0.10,
        author_metadata: 0.05,
        semantic_article_tag: 0.10,
        text_structure: 0.15,
        low_link_density: 0.10,
        h1_present: 0.05
      }

      score = signals.sum { |key, hit| hit ? weights[key] : 0.0 }

      Result.new(article: score >= THRESHOLD, score: score.round(2), signals: signals)
    end

    private

    def detect_jsonld_article_type
      @doc.css('script[type="application/ld+json"]').each do |script|
        data = JSON.parse(script.text.strip)
        return true if jsonld_has_article_type?(data)
      rescue JSON::ParserError
        next
      end
      false
    end

    def jsonld_has_article_type?(data)
      case data
      when Hash
        type = data["@type"]
        types = Array(type)
        return true if types.any? { |t| ARTICLE_JSONLD_TYPES.include?(t) }

        # Check @graph
        if data["@graph"].is_a?(Array)
          return data["@graph"].any? { |item| jsonld_has_article_type?(item) }
        end
      when Array
        return data.any? { |item| jsonld_has_article_type?(item) }
      end
      false
    end

    def detect_og_type_article
      meta = @doc.at_css('meta[property="og:type"]')
      meta&.[]("content")&.downcase == "article"
    end

    def detect_published_timestamp
      return true if @doc.at_css('meta[property="article:published_time"]')
      return true if @doc.at_css("time[datetime]")

      @doc.css('script[type="application/ld+json"]').each do |script|
        data = JSON.parse(script.text.strip)
        return true if jsonld_has_key?(data, "datePublished")
      rescue JSON::ParserError
        next
      end
      false
    end

    def jsonld_has_key?(data, key)
      case data
      when Hash
        return true if data.key?(key)
        return true if data["@graph"].is_a?(Array) && data["@graph"].any? { |item| jsonld_has_key?(item, key) }
      when Array
        return data.any? { |item| jsonld_has_key?(item, key) }
      end
      false
    end

    def detect_author_metadata
      return true if @doc.at_css('meta[name="author"]')
      return true if @doc.at_css('[class*="author"], [class*="byline"], [rel="author"]')

      @doc.css('script[type="application/ld+json"]').each do |script|
        data = JSON.parse(script.text.strip)
        return true if jsonld_has_key?(data, "author")
      rescue JSON::ParserError
        next
      end
      false
    end

    def detect_semantic_article_tag
      @doc.css("article").any? { |el| el.text.strip.length > 500 }
    end

    def detect_text_structure
      paragraphs = content_paragraphs
      return false if paragraphs.size < 3

      avg_words = paragraphs.sum { |p| p.text.strip.split(/\s+/).size } / paragraphs.size.to_f
      avg_words >= 40
    end

    def detect_low_link_density
      main = @doc.at_css("article") || @doc.at_css('[role="main"]') || @doc.at_css("main") || @doc.at_css("body")
      return false unless main

      total_text = main.text.strip
      return false if total_text.length < 200

      link_text = main.css("a").map { |a| a.text.strip }.join
      density = link_text.length.to_f / total_text.length
      density < 0.20
    end

    def detect_h1_present
      h1 = @doc.at_css("h1")
      h1 && h1.text.strip.length > 3
    end

    def content_paragraphs
      container = @doc.at_css("article") || @doc.at_css('[role="main"]') || @doc.at_css("main") || @doc.at_css("body")
      return [] unless container

      container.css("p").select { |p| p.text.strip.split(/\s+/).size >= 10 }
    end
  end
end
