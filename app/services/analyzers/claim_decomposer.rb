module Analyzers
  class ClaimDecomposer
    DecomposedClaim = Struct.new(
      :canonical_text,
      :claim_kind,
      :checkability_status,
      :entities,
      :speaker,
      :time_scope,
      :numeric_value,
      keyword_init: true
    )

    COMPOUND_SIGNALS = /\b(and|also|additionally|moreover|while|but|however|although|whereas|e|também|além disso|mas|porém|enquanto)\b/i
    CONJUNCTION_SPLIT = /\b(?:and|but|while|whereas|however|although|e\b(?:\s+(?:também|ainda))?\s|mas\s|porém\s|enquanto\s)/i

    def self.call(text:, investigation: nil)
      new(text:, investigation:).call
    end

    def initialize(text:, investigation:)
      @text = text.to_s.squish
      @investigation = investigation
    end

    def call
      return [] if @text.blank?

      if compound_claim? && @text.length > 80
        decompose_compound
      else
        [analyze_single(@text)]
      end
    end

    private

    def compound_claim?
      @text.scan(COMPOUND_SIGNALS).length >= 1 && @text.length > 100
    end

    def decompose_compound
      parts = @text.split(CONJUNCTION_SPLIT).map(&:strip).reject { |p| p.length < 25 }
      return [analyze_single(@text)] if parts.length < 2

      parts.map { |part| analyze_single(part) }
    end

    def analyze_single(text)
      DecomposedClaim.new(
        canonical_text: text.squish,
        claim_kind: classify_kind(text),
        checkability_status: CheckabilityClassifier.call(text),
        entities: extract_entities(text),
        speaker: extract_speaker(text),
        time_scope: extract_time_scope(text),
        numeric_value: extract_numeric(text)
      )
    end

    def classify_kind(text)
      return :attribution if text.match?(/\b(said|stated|announced|claimed|according to|afirmou|disse|declarou|segundo)\b/i)
      return :causality if text.match?(/\b(caused|led to|resulted in|because|due to|provocou|causou|resultou|por causa)\b/i)
      return :prediction if text.match?(/\b(will|would|expect|forecast|predict|vai|irá|previsão|estimativa|expectativa)\b/i)
      return :quantity if text.match?(/\b\d[\d,\.]*\s*(%|percent|por cento|bilh|milh|trilh|thousand|million|billion)\b/i)
      :statement
    end

    def extract_entities(text)
      entities = []

      # Named entities (capitalized multi-word phrases)
      text.scan(/([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)/).each do |match|
        value = match[0].strip.sub(/\A(?:The|A|An|O|Os|As|Um|Uma)\s+/i, "")
        entities << { type: "named_entity", value: } if value.length >= 3
      end

      # Organizations (acronyms)
      text.scan(/\b([A-Z]{2,8})\b/).each do |match|
        entities << { type: "organization", value: match[0] } unless %w[THE AND BUT FOR NOT NOR YET GDP PIB CPI].include?(match[0])
      end

      # Monetary values
      text.scan(/(?:R\$|US\$|\$|€)\s*[\d,\.]+(?:\s*(?:bilh|milh|trilh|billion|million|trillion)[a-zõ]*)?/i).each do |match|
        entities << { type: "monetary_value", value: match }
      end

      entities.uniq { |e| e[:value] }.first(10)
    end

    def extract_speaker(text)
      text.match(/\b(?:according to|segundo|conforme|de acordo com)\s+([^,\.]{3,50})/i)&.captures&.first&.squish ||
        text.match(/\b([A-ZÀ-Ý][a-zà-ÿ]+(?:\s+[A-ZÀ-Ý][a-zà-ÿ]+)+)\s+(?:said|stated|announced|afirmou|disse|declarou)\b/i)&.captures&.first&.squish
    end

    def extract_time_scope(text)
      text.match(/\b(in\s+\d{4}|em\s+\d{4}|\d{4}|last\s+(?:year|month|week|quarter)|(?:primeiro|segundo|terceiro|quarto)\s+trimestre|Q[1-4]\s*\d{2,4}|(?:January|February|March|April|May|June|July|August|September|October|November|December|janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)\s+\d{4})\b/i)&.to_s&.squish
    end

    def extract_numeric(text)
      text.match(/\b(\d[\d,\.]*)\s*(%|percent|por cento)\b/i)&.to_s&.squish
    end
  end
end
