module Analyzers
  class EvidenceRelationshipAnalyzer
    NEGATION_PATTERNS = [
      /\bfalse\b/i,
      /\bno evidence\b/i,
      /\bnot true\b/i,
      /\bdebunk/i,
      /\bdeny\b/i,
      /\bdenied\b/i,
      /\bdispute\b/i,
      /\bmisleading\b/i
    ].freeze

    Result = Struct.new(:stance, :relevance_score, keyword_init: true)

    def self.call(claim:, article:)
      new(claim:, article:).call
    end

    def initialize(claim:, article:)
      @claim = claim
      @article = article
    end

    def call
      overlap = token_overlap
      return Result.new(stance: :contextualizes, relevance_score: 0) if overlap.zero?

      stance =
        if contradiction_signals?
          :disputes
        elsif overlap >= 0.28
          :supports
        else
          :contextualizes
        end

      Result.new(stance:, relevance_score: overlap.round(2))
    end

    private

    def token_overlap
      claim_tokens = normalized_tokens(@claim.canonical_text)
      return 0 if claim_tokens.empty?

      article_tokens = normalized_tokens([@article.title, @article.body_text].join(" "))
      matched = claim_tokens & article_tokens
      matched.length.fdiv(claim_tokens.length)
    end

    def contradiction_signals?
      corpus = [@article.title, @article.body_text].join(" ")
      NEGATION_PATTERNS.any? { |pattern| corpus.match?(pattern) }
    end

    def normalized_tokens(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| stop_words.include?(token) }.uniq
    end

    def stop_words
      @stop_words ||= %w[the a an and or but if then this that those these is are was were be been being to for of in on at by from as with said says say]
    end
  end
end
