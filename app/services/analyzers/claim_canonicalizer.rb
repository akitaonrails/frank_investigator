module Analyzers
  class ClaimCanonicalizer
    include LlmHelpers

    CANONICALIZATION_VERSION = 1

    Result = Struct.new(:canonical_form, :semantic_key, keyword_init: true)

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You normalize factual claims into a canonical form for deduplication.

      Rules:
      - canonical_form: Rewrite the claim into a clear Subject-Verb-Object sentence.
        Use proper nouns for entities. Write dates as ISO 8601 (2025-Q1, 2025-03).
        Write percentages as "X%". Remove hedging, attribution, and rhetoric.
        Use present tense for current facts, past tense for past events.
        Keep it factual and concise (one sentence).
      - semantic_key: A lowercase hyphenated key capturing the core assertion.
        Format: primary-entity-metric-or-action-value-time-period
        Max 80 characters. Examples:
        "brazil-gdp-growth-3.1pct-2025-q1"
        "us-unemployment-rate-4.2pct-2025-02"
        "petrobras-revenue-r$120b-2024"

      Return strict JSON matching the schema.
    PROMPT

    def self.call(text:, entities: nil, time_scope: nil)
      new(text:, entities:, time_scope:).call
    end

    def initialize(text:, entities: nil, time_scope: nil)
      @text = text.to_s.squish
      @entities = entities
      @time_scope = time_scope
    end

    def call
      return fallback_result unless llm_available?

      prompt = build_prompt
      response = Timeout.timeout(30) do
        llm_chat(model: canonicalization_model)
          .with_instructions(SYSTEM_PROMPT)
          .with_schema(schema)
          .ask(prompt)
      end

      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(response.content.to_s)
      canonical_form = payload["canonical_form"].to_s.squish
      semantic_key = payload["semantic_key"].to_s.downcase.gsub(/[^a-z0-9\-]/, "-").squeeze("-").truncate(80, omission: "")

      if canonical_form.present? && semantic_key.present?
        Result.new(canonical_form:, semantic_key:)
      else
        fallback_result
      end
    rescue StandardError => e
      Rails.logger.warn("ClaimCanonicalizer failed, using fallback: #{e.message}")
      fallback_result
    end

    private

    def build_prompt
      parts = { claim: @text }
      parts[:entities] = @entities if @entities.present?
      parts[:time_scope] = @time_scope if @time_scope.present?
      parts.to_json
    end

    def schema
      {
        name: "claim_canonicalization",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            canonical_form: { type: "string" },
            semantic_key: { type: "string" }
          },
          required: %w[canonical_form semantic_key]
        }
      }
    end

    def fallback_result
      Result.new(
        canonical_form: @text,
        semantic_key: generate_fallback_key
      )
    end

    def generate_fallback_key
      TextAnalysis.normalize(@text)
        .split(/\s+/)
        .reject { |w| w.length < 3 }
        .first(8)
        .join("-")
        .truncate(80, omission: "")
    end

    def canonicalization_model
      primary_model
    end
  end
end
