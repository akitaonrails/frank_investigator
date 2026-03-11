module Analyzers
  module TextAnalysis
    STOP_WORDS = Set.new(%w[
      the a an is was were are be been being have has had do does did will would shall should
      may might can could of in on at to for with by from as it its this that these those
      and or but not no nor so yet if then than said says say
      o a os as um uma uns umas de do da dos das em no na nos nas por para com
      e ou mas nao nem se que como mais
    ]).freeze

    def self.normalize(text)
      text.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def self.tokenize(text, min_length: 3, remove_stop_words: true)
      tokens = normalize(text).split(/\s+/)
      tokens = tokens.reject { |t| t.length < min_length }
      tokens = tokens.reject { |t| STOP_WORDS.include?(t) } if remove_stop_words
      tokens.to_set
    end

    def self.simple_tokens(text)
      text.to_s.downcase.scan(/[a-z0-9]+/)
    end

    def self.jaccard_similarity(set_a, set_b)
      intersection = (set_a & set_b).size
      union = (set_a | set_b).size
      return 0.0 if union.zero?

      intersection.to_f / union
    end
  end
end
