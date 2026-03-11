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
      :claim_timestamp_start,
      :claim_timestamp_end,
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
      time_scope = extract_time_scope(text)
      ts_start, ts_end = extract_claim_timestamp(time_scope)

      DecomposedClaim.new(
        canonical_text: text.squish,
        claim_kind: classify_kind(text),
        checkability_status: CheckabilityClassifier.call(text),
        entities: extract_entities(text),
        speaker: extract_speaker(text),
        time_scope: time_scope,
        numeric_value: extract_numeric(text),
        claim_timestamp_start: ts_start,
        claim_timestamp_end: ts_end
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

    MONTH_MAP = {
      "january" => 1, "february" => 2, "march" => 3, "april" => 4,
      "may" => 5, "june" => 6, "july" => 7, "august" => 8,
      "september" => 9, "october" => 10, "november" => 11, "december" => 12,
      "janeiro" => 1, "fevereiro" => 2, "março" => 3, "marco" => 3,
      "abril" => 4, "maio" => 5, "junho" => 6, "julho" => 7,
      "agosto" => 8, "setembro" => 9, "outubro" => 10, "novembro" => 11, "dezembro" => 12
    }.freeze

    QUARTER_MONTH = { "1" => [1, 3], "2" => [4, 6], "3" => [7, 9], "4" => [10, 12] }.freeze

    def extract_claim_timestamp(time_scope)
      return [nil, nil] if time_scope.blank?

      scope = time_scope.strip

      # Q1 2026, Q2 25, primeiro trimestre, etc.
      if (qm = scope.match(/Q([1-4])\s*(\d{2,4})/i))
        year = normalize_year(qm[2])
        months = QUARTER_MONTH[qm[1]]
        return [Date.new(year, months[0], 1), Date.new(year, months[1], -1)]
      end

      if (qm = scope.match(/(primeiro|segundo|terceiro|quarto)\s+trimestre/i))
        q = { "primeiro" => "1", "segundo" => "2", "terceiro" => "3", "quarto" => "4" }[qm[1].downcase]
        year_match = scope.match(/(\d{4})/)
        year = year_match ? year_match[1].to_i : Date.current.year
        months = QUARTER_MONTH[q]
        return [Date.new(year, months[0], 1), Date.new(year, months[1], -1)]
      end

      # "March 2025", "fevereiro 2024", "em março 2025"
      MONTH_MAP.each do |name, num|
        if (mm = scope.match(/#{name}\s+(\d{4})/i))
          year = mm[1].to_i
          return [Date.new(year, num, 1), Date.new(year, num, -1)]
        end
      end

      # "in 2024", "em 2024", bare "2024"
      if (ym = scope.match(/\b(\d{4})\b/))
        year = ym[1].to_i
        return [Date.new(year, 1, 1), Date.new(year, 12, 31)]
      end

      [nil, nil]
    end

    def normalize_year(str)
      year = str.to_i
      year < 100 ? year + 2000 : year
    end
  end
end
