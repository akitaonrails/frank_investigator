module Analyzers
  class EvidenceRelationshipAnalyzer
    NEGATION_PATTERNS = [
      /\bfalse\b/i,
      /\bno evidence\b/i,
      /\bnot true\b/i,
      /\bdebunk/i,
      /\bdeny\b/i,
      /\bdenied\b/i,
      /\bdispute\b/i,
      /\bmisleading\b/i,
      /\bincorrect\b/i,
      /\bcontradicts?\b/i,
      /\brefut/i,
      /\binaccurate\b/i,
      /\bwithout\s+(?:evidence|proof|basis)\b/i,
      /\bfailed?\s+to\s+(?:confirm|verify|substantiate)\b/i,
      /\bsem\s+(?:evidência|provas|fundamento)\b/i,
      /\bfalso\b/i,
      /\bdesment/i,
      /\bincorreto\b/i,
      /\bnão\s+(?:é\s+verdade|procede|confirma)\b/i
    ].freeze

    Result = Struct.new(:stance, :relevance_score, :reasoning, keyword_init: true)

    BATCH_SIZE = 15

    def self.call(claim:, article:, investigation: nil)
      new(claim:, article:, investigation:).call
    end

    # Batch-analyze multiple claim-article pairs in a single LLM call.
    # Returns a Hash mapping [claim_id, article_id] => Result.
    def self.call_batch(pairs:, investigation: nil)
      return {} if pairs.empty?

      results = {}

      # Compute heuristics for all pairs first
      heuristic_map = pairs.each_with_object({}) do |pair, hash|
        analyzer = new(claim: pair[:claim], article: pair[:article], investigation:)
        hash["#{pair[:claim].id}:#{pair[:article].id}"] = {
          heuristic: analyzer.send(:heuristic_analysis),
          analyzer:,
          pair:
        }
      end

      # Identify which pairs need LLM analysis
      llm_eligible = heuristic_map.select do |_key, data|
        data[:pair][:article].body_text.to_s.length >= 50
      end

      # Check cache for all eligible pairs
      uncached = {}
      if investigation && llm_available_class?
        llm_eligible.each do |key, data|
          prompt = data[:analyzer].send(:build_contradiction_prompt)
          fingerprint = Digest::SHA256.hexdigest(prompt)
          cached = LlmInteraction.find_cached(
            evidence_packet_fingerprint: fingerprint,
            model_id: contradiction_model_class
          )
          if cached
            llm_result = parse_contradiction_response_class(cached.response_json)
            results[key] = data[:analyzer].send(:merge_analyses, data[:heuristic], llm_result)
          else
            uncached[key] = data
          end
        end
      else
        uncached = llm_eligible
      end

      # Batch LLM call for uncached pairs
      if uncached.any? && llm_available_class?
        uncached.values.each_slice(BATCH_SIZE) do |batch|
          llm_results = batch_llm_analysis(batch, investigation)
          batch.each_with_index do |data, idx|
            key = "#{data[:pair][:claim].id}:#{data[:pair][:article].id}"
            llm_result = llm_results[idx]
            if llm_result
              results[key] = data[:analyzer].send(:merge_analyses, data[:heuristic], llm_result)
            end
          end
        end
      end

      # Fill in any pairs that didn't get LLM analysis (heuristic-only)
      heuristic_map.each do |key, data|
        next if results.key?(key)
        h = data[:heuristic]
        results[key] = Result.new(stance: h[:stance], relevance_score: h[:relevance], reasoning: nil)
      end

      results
    end

    def initialize(claim:, article:, investigation: nil)
      @claim = claim
      @article = article
      @investigation = investigation
    end

    def call
      heuristic = heuristic_analysis
      llm = llm_analysis

      if llm
        merge_analyses(heuristic, llm)
      else
        Result.new(stance: heuristic[:stance], relevance_score: heuristic[:relevance], reasoning: nil)
      end
    end

    private

    def heuristic_analysis
      overlap = token_overlap
      return { stance: :contextualizes, relevance: 0 } if overlap.zero?

      stance = if contradiction_signals?
        :disputes
      elsif overlap >= 0.28
        :supports
      else
        :contextualizes
      end

      { stance:, relevance: overlap.round(2) }
    end

    def llm_analysis
      return nil unless llm_available?
      return nil if @article.body_text.to_s.length < 50

      prompt = build_contradiction_prompt
      fingerprint = Digest::SHA256.hexdigest(prompt)

      if @investigation && (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: contradiction_model))
        return parse_contradiction_response(cached.response_json)
      end

      interaction = record_interaction(prompt, fingerprint)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = RubyLLM.chat(model: contradiction_model, provider: :openrouter, assume_model_exists: true)
        .with_instructions(CONTRADICTION_SYSTEM_PROMPT)
        .with_schema(contradiction_schema)
        .ask(prompt)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(response.content.to_s)
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_contradiction_response(payload)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("LLM contradiction analysis failed: #{e.message}")
      nil
    end

    CONTRADICTION_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a fact-checking evidence analyst. Given a claim and an article, determine:
      1. Does the article support, dispute, or merely contextualize the claim?
      2. How relevant is this article to the claim (0.0 to 1.0)?
      3. A brief reasoning explaining why.
      Base your analysis only on what the article text actually says.
      Return only strict JSON matching the schema.
    PROMPT

    def build_contradiction_prompt
      {
        claim: @claim.canonical_text,
        article_title: @article.title,
        article_excerpt: @article.body_text.to_s.truncate(2000),
        article_source_kind: @article.source_kind,
        article_authority_tier: @article.authority_tier
      }.to_json
    end

    def contradiction_schema
      {
        name: "contradiction_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            stance: { type: "string", enum: %w[supports disputes contextualizes] },
            relevance_score: { type: "number" },
            reasoning: { type: "string" }
          },
          required: %w[stance relevance_score reasoning]
        }
      }
    end

    def parse_contradiction_response(payload)
      {
        stance: payload["stance"].to_s.to_sym,
        relevance: payload["relevance_score"].to_f.clamp(0, 1).round(2),
        reasoning: payload["reasoning"].to_s
      }
    end

    def merge_analyses(heuristic, llm)
      # If heuristic has zero relevance but LLM found something, use LLM
      if heuristic[:relevance].zero? && llm[:relevance] > 0.2
        return Result.new(stance: llm[:stance], relevance_score: llm[:relevance], reasoning: llm[:reasoning])
      end

      # If both agree on stance, boost confidence
      if heuristic[:stance] == llm[:stance]
        relevance = [ heuristic[:relevance], llm[:relevance] ].max
        return Result.new(stance: heuristic[:stance], relevance_score: relevance, reasoning: llm[:reasoning])
      end

      # If they disagree, prefer LLM when it has high relevance and heuristic is weak
      if llm[:relevance] >= 0.5 && heuristic[:relevance] < 0.35
        return Result.new(stance: llm[:stance], relevance_score: llm[:relevance], reasoning: llm[:reasoning])
      end

      # Default: use heuristic stance but average relevance
      avg_relevance = ((heuristic[:relevance] + llm[:relevance]) / 2.0).round(2)
      Result.new(stance: heuristic[:stance], relevance_score: avg_relevance, reasoning: llm[:reasoning])
    end

    def token_overlap
      claim_tokens = normalized_tokens(@claim.canonical_text)
      return 0 if claim_tokens.empty?

      article_tokens = normalized_tokens([ @article.title, @article.body_text ].join(" "))
      matched = claim_tokens & article_tokens
      matched.length.fdiv(claim_tokens.length)
    end

    def contradiction_signals?
      corpus = [ @article.title, @article.body_text ].join(" ")
      NEGATION_PATTERNS.any? { |pattern| corpus.match?(pattern) }
    end

    def normalized_tokens(text)
      TextAnalysis.simple_tokens(text).reject { |token| TextAnalysis::STOP_WORDS.include?(token) }.uniq
    end

    def llm_available?
      defined?(RubyLLM) && ENV["OPENROUTER_API_KEY"].present?
    end

    def contradiction_model
      Array(Rails.application.config.x.frank_investigator.openrouter_models).first || "anthropic/claude-3.7-sonnet"
    end

    def record_interaction(prompt, fingerprint)
      return nil unless @investigation
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :contradiction_analysis,
        model_id: contradiction_model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError
      nil
    end

    def complete_interaction(interaction, response, payload, elapsed_ms)
      return unless interaction
      interaction.update!(
        response_text: response.content.to_s,
        response_json: payload,
        status: :completed,
        latency_ms: elapsed_ms,
        prompt_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
        completion_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil
      )
    rescue StandardError
      nil
    end

    def fail_interaction(interaction, error)
      return unless interaction
      interaction.update!(status: :failed, error_class: error.class.name, error_message: error.message.truncate(500))
    rescue StandardError
      nil
    end

    # --- Class-level batch helpers ---

    BATCH_CONTRADICTION_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a fact-checking evidence analyst. You will receive MULTIPLE claim-article pairs to analyze.

      For each pair, determine:
      1. Does the article support, dispute, or merely contextualize the claim?
      2. How relevant is this article to the claim (0.0 to 1.0)?
      3. A brief reasoning explaining why.

      Rules:
      - Base your analysis ONLY on what each article text actually says.
      - Each analysis is independent — do not let one pair influence another.
      - Be conservative: if unsure, use "contextualizes" with low relevance.

      Return a JSON object with an "analyses" array. Each element must have:
        - stance: one of "supports", "disputes", "contextualizes"
        - relevance_score: between 0.0 and 1.0
        - reasoning: brief text explaining why

      The analyses array MUST have exactly the same number of elements as the pairs array, in the same order.
    PROMPT

    def self.batch_llm_analysis(batch_data, investigation)
      pairs_payload = batch_data.map.with_index do |data, idx|
        {
          index: idx,
          claim: data[:pair][:claim].canonical_text,
          article_title: data[:pair][:article].title,
          article_excerpt: data[:pair][:article].body_text.to_s.truncate(2000),
          article_source_kind: data[:pair][:article].source_kind,
          article_authority_tier: data[:pair][:article].authority_tier
        }
      end

      prompt_text = { pairs: pairs_payload }.to_json
      fingerprint = Digest::SHA256.hexdigest(prompt_text)
      model = contradiction_model_class

      # Check batch cache
      if investigation
        cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model)
        if cached&.response_json.is_a?(Hash) && cached.response_json["analyses"].is_a?(Array)
          return cached.response_json["analyses"].map { |a| parse_contradiction_response_class(a) }
        end
      end

      interaction = if investigation
        LlmInteraction.create!(
          investigation:,
          interaction_type: :contradiction_analysis,
          model_id: model,
          prompt_text: prompt_text,
          evidence_packet_fingerprint: fingerprint,
          status: :pending
        )
      end

      count = batch_data.size
      schema = {
        name: "batch_contradiction_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            analyses: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  stance: { type: "string", enum: %w[supports disputes contextualizes] },
                  relevance_score: { type: "number" },
                  reasoning: { type: "string" }
                },
                required: %w[stance relevance_score reasoning]
              },
              minItems: count,
              maxItems: count
            }
          },
          required: %w[analyses]
        }
      }

      timeout = ENV.fetch("LLM_TIMEOUT_SECONDS", 120).to_i * 2
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = Timeout.timeout(timeout) do
        RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)
          .with_instructions(BATCH_CONTRADICTION_SYSTEM_PROMPT)
          .with_schema(schema)
          .ask(prompt_text)
      end

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(response.content.to_s)

      if interaction
        interaction.update!(
          response_text: response.content.to_s.delete("\x00"),
          response_json: payload,
          status: :completed,
          latency_ms: elapsed_ms,
          prompt_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
          completion_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil
        )
      end

      payload.fetch("analyses").map { |a| parse_contradiction_response_class(a) }
    rescue StandardError => e
      Rails.logger.warn("[EvidenceRelationshipAnalyzer] Batch LLM failed: #{e.message}")
      interaction&.update!(status: :failed, error_class: e.class.name, error_message: e.message.truncate(500)) rescue nil
      Array.new(batch_data.size) # Return nils so callers fall back to heuristic
    end

    def self.llm_available_class?
      defined?(RubyLLM) && ENV["OPENROUTER_API_KEY"].present?
    end

    def self.contradiction_model_class
      Array(Rails.application.config.x.frank_investigator.openrouter_models).first || "anthropic/claude-3.7-sonnet"
    end

    def self.parse_contradiction_response_class(payload)
      return nil unless payload.is_a?(Hash)
      {
        stance: payload["stance"].to_s.to_sym,
        relevance: payload["relevance_score"].to_f.clamp(0, 1).round(2),
        reasoning: payload["reasoning"].to_s
      }
    end
  end
end
