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

    # Euphemistic/softening headline language that downplays severity
    DOWNPLAY_HEADLINE_PATTERNS = [
      /\btomou\b/i, /\blevou\b/i, /\bpegou\b/i,     # Portuguese: took (soft for stole)
      /\bpesquisador[a]?\b/i,                          # Portuguese: researcher (humanizing label)
      /\bincidente\b/i,                                # Portuguese: incident (soft for crime)
      /\benvolvid[oa]\b/i,                             # Portuguese: involved (passive)
      /\bobteve\s+direito\b/i,                         # Portuguese: obtained the right (framing tragedy as empowerment)
      /\bcom\s+direito\b/i,                            # Portuguese: with the right to
      /\boptou\b/i, /\bescolheu\b/i,                  # Portuguese: chose/opted (agency framing for forced situations)
      /\bquem\s+é\b/i,                                 # Portuguese: who is (humanizing profile framing)
      /\btook\b/i, /\bremoved?\b/i, /\baccessed?\b/i, # English: soft verbs
      /\bresearcher\b/i, /\bscientist\b/i,            # humanizing labels
      /\bincident\b/i, /\bevent\b/i, /\bsituation\b/i, # minimizing nouns
      /\bobtained?\s+the\s+right\b/i,                 # English: obtained the right
      /\bchose\s+to\b/i, /\bopted\s+for\b/i           # English: agency framing
    ].freeze

    # Severe body language that the headline should reflect but doesn't
    SEVERITY_BODY_PATTERNS = [
      /\broubou?\b/i, /\bfurtou?\b/i,                 # Portuguese: stole/robbed
      /\bpreso\b/i, /\bpresos?\b/i, /\bdeti[dv]/i,    # Portuguese: arrested/detained
      /\bcrim[ei]/i,                                    # Portuguese: crime/criminal
      /\barma\s+biológica\b/i, /\bvírus\b/i,          # Portuguese: bioweapon/virus
      /\bperigo/i, /\brisco\b/i, /\bameaça\b/i,       # Portuguese: danger/risk/threat
      /\bstole\b/i, /\btheft\b/i, /\brobbed?\b/i,
      /\barrested?\b/i, /\bdetained?\b/i, /\bcharged?\b/i,
      /\bbioweapon/i, /\bdangerous\b/i, /\bthreat\b/i, /\blethal\b/i,
      /\bhazard/i, /\bcontaminat/i
    ].freeze

    # Positive framing words in headlines
    POSITIVE_HEADLINE_PATTERNS = [
      /\bcort[aou]\b/i,              # Portuguese: cuts
      /\breduz\b/i,                  # Portuguese: reduces
      /\bze?rou\b/i,                 # Portuguese: zeroed
      /\bisen[çt]/i,                 # Portuguese: exempts
      /\bbenefíci/i,                 # Portuguese: benefits
      /\baument[oa]\b.*\b(empregos?|salário|crescimento)\b/i,
      /\bcuts?\b/i, /\breduc/i, /\blowers?\b/i, /\bboosts?\b/i, /\bbenefits?\b/i
    ].freeze

    # Qualifying/negative body language that contradicts positive headline framing
    QUALIFYING_BODY_PATTERNS = [
      /\brecuo\b/i, /\brecuou\b/i,          # Portuguese: retreated/reversed
      /\breação\s+contrária\b/i,             # Portuguese: backlash
      /\bpressão\b/i,                         # Portuguese: pressure
      /\bantes\s+havia\s+(aument|elevad)/i,  # Portuguese: previously had increased
      /\boriginalmente\b/i,                   # Portuguese: originally
      /\bvoltou\s+atrás\b/i,                 # Portuguese: walked back
      /\bpolêmic/i,                           # Portuguese: controversial
      /\bcríticas?\b/i,                       # Portuguese: criticism
      /\brevert/i, /\brollback\b/i, /\bbacklash\b/i, /\breversed?\b/i,
      /\bpreviously\s+(raised?|increased?|imposed)/i,
      /\bwalked?\s+back\b/i, /\bU-turn\b/i, /\bbacktrack/i
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
        [ definitive_claims * 0.15 + hedging_signals * 0.08, 0.5 ].min
      else
        0
      end

      # Selective positive framing: headline uses positive framing but body contains
      # qualifying/negative context (reversals, backlash, prior increases)
      positive_headline = POSITIVE_HEADLINE_PATTERNS.count { |p| title.to_s.match?(p) }
      qualifying_body = QUALIFYING_BODY_PATTERNS.count { |p| body_text_str.match?(p) }
      selective_framing = if positive_headline > 0 && qualifying_body >= 2
        [ positive_headline * 0.1 + qualifying_body * 0.06, 0.45 ].min
      else
        0
      end

      # Euphemistic downplaying: headline uses soft/humanizing language while
      # the body describes severe events (theft, arrest, danger, bioweapons)
      downplay_headline = DOWNPLAY_HEADLINE_PATTERNS.count { |p| title.to_s.match?(p) }
      severity_body = SEVERITY_BODY_PATTERNS.count { |p| body_text_str.match?(p) }
      downplaying = if downplay_headline > 0 && severity_body >= 2
        [ downplay_headline * 0.12 + severity_body * 0.05, 0.5 ].min
      else
        0
      end

      score = ((unsupported_ratio * 0.5) + (sensationality * 0.7) + (escalation * 0.8) + (selective_framing * 0.7) + (downplaying * 0.7)).clamp(0, 1)

      Result.new(
        score: (score * 100).round(2),
        reason: reason_for(score, escalation, selective_framing, downplaying),
        definitive_claims: definitive_claims,
        hedging_signals: hedging_signals
      )
    end

    def self.tokenize(text)
      TextAnalysis.simple_tokens(text)
    end
    private_class_method :tokenize

    def self.reason_for(score, escalation, selective_framing = 0, downplaying = 0)
      key = if downplaying > 0.15
        "downplaying"
      elsif selective_framing > 0.15
        "selective_positive"
      elsif escalation > 0.2
        "escalation"
      elsif score < 0.25
        "low"
      elsif score < 0.6
        "moderate"
      else
        "high"
      end
      I18n.t("helpers.headline_bait.#{key}")
    end
    private_class_method :reason_for
  end
end
