module Analyzers
  class ClaimSimilarityMatcher
    include LlmHelpers

    SIMILARITY_THRESHOLD = 0.55
    ENTITY_OVERLAP_MINIMUM = 0.4
    MAX_LLM_CANDIDATES = 5

    Match = Struct.new(:claim, :similarity_score, :match_method, keyword_init: true)

    def self.call(text:, candidates: nil, use_llm: false, investigation: nil)
      new(text:, candidates:, use_llm:, investigation:).call
    end

    def initialize(text:, candidates:, use_llm: false, investigation: nil)
      @text = text.to_s.squish
      @candidates = candidates || Claim.all
      @use_llm = use_llm
      @investigation = investigation
    end

    def call
      return [] if @text.blank?

      # Tier 1: Jaccard + entity overlap pre-filter
      prefilter_matches = jaccard_matches
      return prefilter_matches unless @use_llm

      # Tier 2: LLM equivalence for borderline candidates (0.4..0.7 Jaccard)
      borderline = prefilter_matches.select { |m| m.similarity_score.between?(0.4, 0.69) }
      if borderline.any?
        llm_confirmed = check_llm_equivalence(borderline.first(MAX_LLM_CANDIDATES))
        prefilter_matches = (prefilter_matches.reject { |m| m.similarity_score < 0.7 } + llm_confirmed)
          .sort_by { |m| -m.similarity_score }
      end

      prefilter_matches
    end

    private

    def jaccard_matches
      query_tokens = TextAnalysis.tokenize(@text, min_length: 2)
      return [] if query_tokens.empty?

      query_entities = extract_entity_values(@text)

      @candidates.filter_map do |claim|
        candidate_text = claim.canonical_form.presence || claim.canonical_text
        candidate_tokens = TextAnalysis.tokenize(candidate_text, min_length: 2)
        next if candidate_tokens.empty?

        jaccard = TextAnalysis.jaccard_similarity(query_tokens, candidate_tokens)

        # Boost score if entities overlap significantly
        if jaccard >= 0.3 && query_entities.any?
          candidate_entities = extract_entity_values_from_claim(claim)
          if candidate_entities.any?
            entity_overlap = entity_overlap_score(query_entities, candidate_entities)
            jaccard = (jaccard * 0.6 + entity_overlap * 0.4).round(3) if entity_overlap >= ENTITY_OVERLAP_MINIMUM
          end
        end

        next if jaccard < SIMILARITY_THRESHOLD

        Match.new(claim:, similarity_score: jaccard.round(3), match_method: :jaccard)
      end.sort_by { |m| -m.similarity_score }
    end

    def extract_entity_values(text)
      entities = []
      # Named entities (capitalized multi-word)
      text.scan(/([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)/).each { |m| entities << m[0].downcase }
      # Acronyms
      text.scan(/\b([A-Z]{2,8})\b/).each { |m| entities << m[0].downcase }
      # Numbers with context
      text.scan(/\b(\d[\d,\.]*\s*%?)\b/).each { |m| entities << m[0].gsub(/\s/, "") }
      entities.to_set
    end

    def extract_entity_values_from_claim(claim)
      entities = Set.new
      Array(claim.entities_json).each do |e|
        entities << e["value"].to_s.downcase if e["value"].present?
      end
      # Also extract from text if entities_json is sparse
      entities.merge(extract_entity_values(claim.canonical_form.presence || claim.canonical_text)) if entities.size < 2
      entities
    end

    def entity_overlap_score(set_a, set_b)
      intersection = (set_a & set_b).size
      smaller = [ set_a.size, set_b.size ].min
      return 0.0 if smaller.zero?
      intersection.to_f / smaller
    end

    def check_llm_equivalence(candidates)
      return [] unless llm_available?

      prompt = build_equivalence_prompt(candidates)
      response = Timeout.timeout(30) do
        llm_chat(model: equivalence_model)
          .with_instructions(EQUIVALENCE_SYSTEM_PROMPT)
          .with_schema(equivalence_schema(candidates.size))
          .ask(prompt)
      end

      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(response.content.to_s)
      parse_equivalence_results(payload, candidates)
    rescue StandardError => e
      Rails.logger.warn("LLM equivalence check failed: #{e.message}")
      []
    end

    EQUIVALENCE_SYSTEM_PROMPT = <<~PROMPT.freeze
      You compare factual claims for semantic equivalence. Two claims are equivalent if they
      assert the same core fact, even if worded differently. Differences in attribution,
      hedging, or minor phrasing do not matter. Differences in numbers, dates, entities,
      or the actual assertion DO matter.
      Return strict JSON matching the schema.
    PROMPT

    def build_equivalence_prompt(candidates)
      comparisons = candidates.map.with_index do |match, i|
        { index: i, claim_a: @text, claim_b: match.claim.canonical_form.presence || match.claim.canonical_text }
      end
      { comparisons: comparisons }.to_json
    end

    def equivalence_schema(count)
      {
        name: "claim_equivalence",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            results: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  index: { type: "integer" },
                  equivalent: { type: "boolean" },
                  confidence: { type: "number" }
                },
                required: %w[index equivalent confidence]
              }
            }
          },
          required: %w[results]
        }
      }
    end

    def parse_equivalence_results(payload, candidates)
      Array(payload["results"]).filter_map do |result|
        next unless result["equivalent"] == true && result["confidence"].to_f >= 0.7

        idx = result["index"].to_i
        candidate = candidates[idx]
        next unless candidate

        Match.new(
          claim: candidate.claim,
          similarity_score: result["confidence"].to_f.round(3),
          match_method: :llm_equivalence
        )
      end
    end

    def equivalence_model
      primary_model
    end
  end
end
