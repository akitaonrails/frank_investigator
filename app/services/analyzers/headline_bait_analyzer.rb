module Analyzers
  class HeadlineBaitAnalyzer
    SENSATIONAL_TERMS = %w[shocking bombshell exposed unbelievable secret slammed destroys humiliates breaking exclusive].freeze

    # Headline language that states something as fact/definitive
    DEFINITIVE_HEADLINE_PATTERNS = [
      /\baccused\s+of\b/i,
      /\bcaught\b/i,
      /\bconfirmed?\b/i,
      /\brevealed?\b/i,
      /\bproven\b/i,
      /\bguilt/i,
      /\bscandal\b/i,
      /\bcorrupt/i,
      /\bfraud\b/i,
      /\bcriminal\b/i,
      /\billegal\b/i,
      /\bacusad[oa]\b/i,      # Portuguese
      /\bescândalo\b/i,
      /\bcomprovad[oa]\b/i,
      /\brevelad[oa]\b/i,
      /\bfraude\b/i
    ].freeze

    # Body language that hedges, qualifies, or undermines the headline's certainty
    HEDGING_PATTERNS = [
      /\balleged(ly)?\b/i,
      /\bclaimed?\b/i,
      /\baccording\s+to\s+(unnamed|anonymous|a?\s*source)/i,
      /\breportedly\b/i,
      /\bunconfirmed\b/i,
      /\bunverified\b/i,
      /\brunaway\s+rum/i,
      /\bnot\s+(yet\s+)?(been\s+)?(confirmed|verified|proven|charged|arrested|convicted)\b/i,
      /\bno\s+(official\s+)?(police\s+)?(report|charges?|arrest|conviction|evidence|proof|confirmation)\b/i,
      /\bdenied?\s+(the\s+)?(allegations?|accusations?|claims?|charges?)\b/i,
      /\bpending\s+(investigation|inquiry|review)\b/i,
      /\bhas\s+not\s+(responded|commented)\b/i,
      /\bcould\s+not\s+(be\s+)?(reached|confirmed|verified|independently\s+verified)\b/i,
      /\bsources?\s+(say|claim|suggest|indicate|told)\b/i,
      /\bneighbou?rs?\s+(say|claim|heard|reported)\b/i,
      /\bwitnesses?\s+(say|claim|reported)\b/i,
      /\brumou?rs?\b/i,
      /\bspeculat/i,
      /\bsupostamente\b/i,     # Portuguese: supposedly
      /\balegad[oa]mente\b/i,  # Portuguese: allegedly
      /\bsegundo\s+fontes\b/i, # Portuguese: according to sources
      /\bnão\s+(foi|foram)\s+(confirmad|verificad)/i,  # Portuguese: not confirmed
      /\bsem\s+(boletim|registro|queixa)\b/i,          # Portuguese: no police report
      /\bneg(ou|aram)\s+(as?\s+)?acusaç/i              # Portuguese: denied accusations
    ].freeze

    Result = Struct.new(:score, :reason, :definitive_claims, :hedging_signals, keyword_init: true)

    def self.call(title:, body_text:)
      title_words = tokenize(title)
      body_words = tokenize(body_text)
      body_text_str = body_text.to_s

      unsupported_ratio = if title_words.empty?
        0
      else
        (title_words - body_words).length.fdiv(title_words.length)
      end

      sensationality = title_words.count { |word| SENSATIONAL_TERMS.include?(word) } * 0.2

      # Escalation detection: headline states definitively, body hedges
      definitive_claims = DEFINITIVE_HEADLINE_PATTERNS.count { |p| title.to_s.match?(p) }
      hedging_signals = HEDGING_PATTERNS.count { |p| body_text_str.match?(p) }
      escalation = if definitive_claims > 0 && hedging_signals > 0
        [definitive_claims * 0.15 + hedging_signals * 0.08, 0.5].min
      else
        0
      end

      score = ((unsupported_ratio * 0.5) + (sensationality * 0.7) + (escalation * 0.8)).clamp(0, 1)

      Result.new(
        score: (score * 100).round(2),
        reason: reason_for(score, escalation),
        definitive_claims: definitive_claims,
        hedging_signals: hedging_signals
      )
    end

    def self.tokenize(text)
      TextAnalysis.simple_tokens(text)
    end
    private_class_method :tokenize

    def self.reason_for(score, escalation)
      if escalation > 0.2
        "Headline makes definitive claims that the article body does not substantiate. The body contains hedging language (alleged, unconfirmed, sources say) that contradicts the headline's certainty."
      elsif score < 0.25
        "Headline largely matches the article body."
      elsif score < 0.6
        "Headline is somewhat stronger than the body evidence."
      else
        "Headline appears materially more sensational than the article body."
      end
    end
    private_class_method :reason_for
  end
end
