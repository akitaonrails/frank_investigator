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

      query_tokens = tokenize(@text)
      return [] if query_tokens.empty?

      @candidates.filter_map do |claim|
        candidate_tokens = tokenize(claim.canonical_text)
        next if candidate_tokens.empty?

        score = jaccard_similarity(query_tokens, candidate_tokens)
        next if score < SIMILARITY_THRESHOLD

        Match.new(claim:, similarity_score: score.round(3))
      end.sort_by { |m| -m.similarity_score }
    end

    private

    def tokenize(text)
      normalized = ClaimFingerprint.call(text)
      tokens = normalized.split(/\s+/)
      tokens.reject { |t| stop_word?(t) || t.length < 2 }.to_set
    end

    def jaccard_similarity(set_a, set_b)
      intersection = (set_a & set_b).size
      union = (set_a | set_b).size
      return 0.0 if union.zero?

      intersection.to_f / union
    end

    STOP_WORDS = Set.new(%w[
      the a an is was were are be been being have has had do does did will would shall should
      may might can could of in on at to for with by from as it its this that these those
      and or but not no nor so yet if then than
      o a os as um uma uns umas de do da dos das em no na nos nas por para com
      e ou mas nao nem se que como mais
    ]).freeze

    def stop_word?(token)
      STOP_WORDS.include?(token)
    end
  end
end
