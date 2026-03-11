module Analyzers
  class ClaimSimilarityMatcher
    SIMILARITY_THRESHOLD = 0.55

    Match = Struct.new(:claim, :similarity_score, keyword_init: true)

    def self.call(text:, candidates: nil)
      new(text:, candidates:).call
    end

    def initialize(text:, candidates:)
      @text = text.to_s.squish
      @candidates = candidates || Claim.all
    end

    def call
      return [] if @text.blank?

      query_tokens = TextAnalysis.tokenize(@text, min_length: 2)
      return [] if query_tokens.empty?

      @candidates.filter_map do |claim|
        candidate_tokens = TextAnalysis.tokenize(claim.canonical_text, min_length: 2)
        next if candidate_tokens.empty?

        score = TextAnalysis.jaccard_similarity(query_tokens, candidate_tokens)
        next if score < SIMILARITY_THRESHOLD

        Match.new(claim:, similarity_score: score.round(3))
      end.sort_by { |m| -m.similarity_score }
    end
  end
end
