require "set"

module Analyzers
  class ClaimExtractor
    include LlmHelpers

    Result = Struct.new(:canonical_text, :surface_text, :role, :checkability_status, :importance_score, :canonical_form, :semantic_key, keyword_init: true)

    MAX_LLM_INPUT_LENGTH = 3000

    def self.call(article, investigation: nil)
      new(article, investigation:).call
    end

    def initialize(article, investigation: nil)
      @article = article
      @investigation = investigation
    end

    def call
      llm_claims = extract_with_llm
      # When LLM extraction succeeds, use only LLM claims — they are higher quality
      # and the heuristic headline/body claims are redundant duplicates.
      # Fall back to heuristic only when LLM is unavailable or returns nothing.
      candidates = if llm_claims.any?
        llm_claims
      else
        heuristic_candidates
      end
      candidates.uniq { |result| ClaimFingerprint.call(result.canonical_text) }
    end

    private

    def heuristic_candidates
      results = []
      results.concat(extract_title_claims)
      results.concat(extract_body_claims)
      results
    end

    def extract_title_claims
      return [] if @article.title.blank?
      result = build_result(@article.title, role: :headline, importance_score: 1.0)
      result ? [ result ] : []
    end

    def extract_body_claims
      sentences.first(3).filter_map.with_index do |sentence, index|
        next if index.positive? && !central_sentence?(sentence)

        build_result(sentence, role: index.zero? ? :lead : :body, importance_score: index.zero? ? 0.85 : 0.65)
      end
    end

    def extract_with_llm
      return [] unless llm_available?

      body_sample = @article.body_text.to_s.truncate(MAX_LLM_INPUT_LENGTH)
      return [] if body_sample.length < 100

      prompt = build_llm_prompt(body_sample)
      packet_fingerprint = Digest::SHA256.hexdigest(prompt)

      interaction = record_interaction(prompt, packet_fingerprint)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = llm_chat(model: extraction_model)
        .with_instructions(EXTRACTION_SYSTEM_PROMPT)
        .with_schema(extraction_schema)
        .ask(prompt)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i
      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_llm_claims(payload)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("LLM claim extraction failed: #{e.message}")
      []
    end

    EXTRACTION_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a fact-checking claim extractor. Given a news article, identify ONLY the core newsworthy factual claims.

      EXTRACT only claims that are:
      - Verifiable against official records, data, or documents
      - Central to the article's news value (not background or filler)
      - Specific enough to check (names, dates, numbers, official actions)

      DO NOT extract:
      - Opinions, rhetoric, or editorial commentary
      - Generic background context ("Brazil is the largest country in South America")
      - Website UI text, navigation, cookie notices, social share prompts
      - Author bylines, publication dates, or metadata
      - Vague or hedged statements ("some analysts believe")
      - Duplicate or near-duplicate claims (pick the most specific version)

      Aim for 3-8 high-quality claims per article. Fewer precise claims are better than many vague ones.

      For each claim, provide:
      - text: the claim as stated in the article
      - canonical_form: the claim rewritten as a clear Subject-Verb-Object sentence with proper nouns,
        ISO dates (2025-Q1, 2025-03), percentages as "X%", no hedging or attribution
      - semantic_key: a lowercase hyphenated key like "brazil-gdp-growth-3.1pct-2025-q1" (max 80 chars)
      - importance: high, medium, or low
      - checkability: checkable, not_checkable, or ambiguous
      Return only strict JSON matching the schema.
    PROMPT

    def build_llm_prompt(body_sample)
      {
        title: @article.title,
        body: body_sample,
        host: @article.host
      }.to_json
    end

    def extraction_schema
      {
        name: "claim_extraction",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            claims: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  text: { type: "string" },
                  canonical_form: { type: "string" },
                  semantic_key: { type: "string" },
                  importance: { type: "string", enum: %w[high medium low] },
                  checkability: { type: "string", enum: %w[checkable not_checkable ambiguous] }
                },
                required: %w[text canonical_form semantic_key importance checkability]
              }
            }
          },
          required: %w[claims]
        }
      }
    end

    def parse_llm_claims(payload)
      Array(payload["claims"]).filter_map do |claim_data|
        text = claim_data["text"].to_s.squish
        next if text.blank? || text.length < 30
        next if ClaimNoiseFilter.noise?(text)

        importance = case claim_data["importance"]
        when "high" then 0.95
        when "medium" then 0.75
        else 0.55
        end

        checkability = claim_data["checkability"].to_s
        checkability = "pending" unless %w[checkable not_checkable ambiguous].include?(checkability)

        Result.new(
          canonical_text: text,
          surface_text: text,
          role: :body,
          checkability_status: checkability.to_sym,
          importance_score: importance,
          canonical_form: claim_data["canonical_form"].to_s.squish.presence,
          semantic_key: claim_data["semantic_key"].to_s.downcase.gsub(/[^a-z0-9\-]/, "-").squeeze("-").truncate(80, omission: "").presence
        )
      end
    end

    def merge_llm_claims(heuristic, llm_claims)
      existing_fingerprints = heuristic.map { |r| ClaimFingerprint.call(r.canonical_text) }.to_set

      llm_claims.each do |llm_claim|
        fp = ClaimFingerprint.call(llm_claim.canonical_text)
        next if existing_fingerprints.include?(fp)

        # Check if LLM found something that overlaps with heuristic via similarity
        tokens = TextAnalysis.tokenize(llm_claim.canonical_text)
        already_covered = heuristic.any? do |h|
          TextAnalysis.jaccard_similarity(tokens, TextAnalysis.tokenize(h.canonical_text)) > 0.6
        end
        next if already_covered

        heuristic << llm_claim
        existing_fingerprints << fp
      end

      heuristic
    end

    def build_result(sentence, role:, importance_score:)
      surface_text = sentence.to_s.squish
      return nil if surface_text.blank? || surface_text.length < 30
      return nil if ClaimNoiseFilter.noise?(surface_text)

      Result.new(
        canonical_text: surface_text,
        surface_text:,
        role:,
        checkability_status: CheckabilityClassifier.call(surface_text),
        importance_score:
      )
    end

    def sentences
      text = @article.body_text.to_s.squish
      return [] if text.blank?
      text.split(/(?<=[.!?])\s+/).map(&:strip)
    end

    def central_sentence?(sentence)
      return true if @article.title.blank?

      sentence_tokens = normalized_tokens_for(sentence)
      return false if sentence_tokens.empty?

      title_tokens = normalized_tokens_for(@article.title)
      return true if (sentence_tokens & title_tokens).size >= 2

      title_subjects = extract_title_subject_tokens
      title_subjects.any? { |token| sentence_tokens.include?(token) }
    end

    def extract_title_subject_tokens
      @extract_title_subject_tokens ||= @article.title.to_s.scan(/\b[A-ZÀ-Ú][a-zà-ú]{4,}\b/)
        .map(&:downcase)
        .to_set
    end

    def normalized_tokens_for(text)
      text.to_s.downcase.scan(/[[:alnum:]][[:alnum:]\-]+/).to_set
    end

    def interaction_type_name
      :claim_decomposition
    end

    def extraction_model
      primary_model
    end

    def record_interaction(prompt, fingerprint)
      return nil unless @investigation
      create_interaction(extraction_model, prompt, fingerprint)
    end
  end
end
