module Analyzers
  class ClaimNoiseFilter
    UI_BOILERPLATE_PATTERNS = [
      /\bcookie/i,
      /\bconsent/i,
      /\baceitar\b/i,
      /\bnewsletter\b/i,
      /\binscreva-se\b/i,
      /\bsubscri(?:be|ption)\b/i,
      /\bsign\s+(?:in|up|out)\b/i,
      /\blog\s*(?:in|out)\b/i,
      /\bentrar\b.*\bcadast/i,
      /\bcompartilh(?:ar|e)\b.*\b(?:facebook|twitter|whatsapp)\b/i,
      /\bshare\s+(?:on|this)\b/i,
      /\bbaixe?\s+(?:o\s+)?app\b/i,
      /\bdownload\s+(?:the\s+)?app\b/i
    ].freeze

    METADATA_PATTERNS = [
      /\A(?:por|by)\s+[A-Z][a-záéíóúãõç]+\s+[A-Z]/i,         # "Por João Silva" / "By John Smith"
      /\batualizado\s+(?:há|em)\b/i,                            # "Atualizado há 2 horas"
      /\bupdated?\s+(?:on|at)\b/i,                              # "Updated on March 10"
      /\AArticle metadata:/i,
      /\A\d{1,2}\/\d{1,2}\/\d{2,4}\z/,                         # date-only string
      /\A\d{1,2}\s+(?:de\s+)?(?:jan|fev|mar|abr|mai|jun|jul|ago|set|out|nov|dez)/i
    ].freeze

    PORTAL_BOILERPLATE = [
      "Fala.BR",
      "Plataforma Integrada",
      "Ouvidoria e Acesso à Informação",
      "Plataforma Integrada de Ouvidoria"
    ].freeze

    def self.noise?(text)
      new(text).noise?
    end

    def initialize(text)
      @text = text.to_s.squish
    end

    def noise?
      return true if ui_boilerplate?
      return true if metadata?
      return true if portal_boilerplate?
      return true if concatenated_headlines?
      return true if fragment_too_short?
      false
    end

    private

    def ui_boilerplate?
      UI_BOILERPLATE_PATTERNS.any? { |p| @text.match?(p) }
    end

    def metadata?
      METADATA_PATTERNS.any? { |p| @text.match?(p) }
    end

    def portal_boilerplate?
      PORTAL_BOILERPLATE.any? { |phrase| @text.include?(phrase) }
    end

    def concatenated_headlines?
      # 3+ capitalized segments with no sentence-ending punctuation between them
      segments = @text.split(/\s{2,}|\t|\s*\|\s*/).reject(&:blank?)
      return false if segments.size < 3

      capitalized = segments.count { |s| s.match?(/\A[A-ZÁÉÍÓÚÃÕÇ]/) }
      no_period = segments.none? { |s| s.match?(/[.!?]\z/) }
      capitalized >= 3 && no_period
    end

    def fragment_too_short?
      return false if @text.length >= 40
      # Short text with no verb-like word is likely a fragment
      !@text.match?(/\b(?:is|are|was|were|has|have|had|will|would|could|should|can|do|does|did|said|says|announced|confirmed|reported|é|são|foi|foram|tem|teve|será|pode|deve|disse|afirmou|anunciou|confirmou)\b/i)
    end
  end
end
