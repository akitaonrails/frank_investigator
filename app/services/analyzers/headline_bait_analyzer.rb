module Analyzers
  class HeadlineBaitAnalyzer
    SENSATIONAL_TERMS = %w[shocking bombshell exposed unbelievable secret slammed destroys humiliates].freeze

    Result = Struct.new(:score, :reason, keyword_init: true)

    def self.call(title:, body_text:)
      title_words = tokenize(title)
      body_words = tokenize(body_text)

      unsupported_ratio = if title_words.empty?
        0
      else
        (title_words - body_words).length.fdiv(title_words.length)
      end

      sensationality = title_words.count { |word| SENSATIONAL_TERMS.include?(word) } * 0.2
      score = ((unsupported_ratio * 0.7) + sensationality).clamp(0, 1)

      Result.new(
        score: (score * 100).round(2),
        reason: reason_for(score)
      )
    end

    def self.tokenize(text)
      TextAnalysis.simple_tokens(text)
    end
    private_class_method :tokenize

    def self.reason_for(score)
      return "Headline largely matches the article body." if score < 0.25
      return "Headline is somewhat stronger than the body evidence." if score < 0.6

      "Headline appears materially more sensational than the article body."
    end
    private_class_method :reason_for
  end
end
