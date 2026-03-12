module Llm
  class RubyLlmClient
    Result = Struct.new(:verdict, :confidence_score, :reason_summary, :model_results, :disagreement_details, :unanimous, keyword_init: true)

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are part of a news fact-checking pipeline. Your task is to assess a claim based on retrieved evidence.

      Rules:
      - Base your assessment ONLY on the provided evidence, not your own knowledge.
      - Cite specific evidence items by their source URL or title in your reasoning.
      - If evidence is insufficient to reach a conclusion, say so explicitly.
      - If sources disagree, note the disagreement and which sources are more authoritative.
      - Be conservative: prefer "needs_more_evidence" over weak "supported" or "disputed".

      Return only strict JSON with keys: verdict, confidence_score, reason_summary.
      Use verdict values: supported, disputed, mixed, needs_more_evidence, not_checkable.
      confidence_score must be between 0.0 and 0.97.
      reason_summary must reference specific evidence sources.

      IMPORTANT: The verdict field must always use one of the English enum values above.
      However, write the reason_summary text in %{locale_name}.
    PROMPT

    VERDICT_ORDER = %w[supported mixed disputed needs_more_evidence not_checkable].freeze

    def initialize(models: Rails.application.config.x.frank_investigator.openrouter_models)
      quarantined = ENV.fetch("QUARANTINED_MODELS", "").split(",").map(&:strip).reject(&:blank?)
      @models = Array(models).reject { |m| quarantined.include?(m) }
    end

    def call(claim:, evidence_packet:, investigation: nil, claim_assessment: nil)
      return nil unless available?

      prompt_text = build_prompt(claim:, evidence_packet:)
      packet_fingerprint = Digest::SHA256.hexdigest(prompt_text)

      results = @models.filter_map do |model|
        ask_model(
          model:, claim:, evidence_packet:,
          prompt_text:, packet_fingerprint:,
          investigation:, claim_assessment:
        )
      rescue StandardError
        nil
      end

      return nil if results.empty?

      aggregate_results(results)
    end

    def available?
      defined?(RubyLLM) && ENV["OPENROUTER_API_KEY"].present? && @models.any?
    end

    private

    def aggregate_results(results)
      verdict_groups = results.group_by(&:verdict)
      # Weighted vote: sum confidence scores per verdict, not head count.
      # A single model at 0.95 outweighs two models at 0.40.
      majority_verdict = verdict_groups.max_by { |_, votes| votes.sum { |r| r.confidence_score.to_f } }&.first || "needs_more_evidence"
      mean_confidence = results.sum { |r| r.confidence_score.to_f } / results.size

      # Graduated disagreement penalty based on verdict distance
      disagreement_penalty = compute_disagreement_penalty(results)
      unanimous = results.map(&:verdict).uniq.one?

      # Build per-model details string
      model_results = results.map { |r| { verdict: r.verdict, confidence: r.confidence_score } }
      details_parts = results.map { |r| "#{r.verdict} (#{(r.confidence_score.to_f * 100).round}%)" }
      disagreement_details = unanimous ? "All models agree: #{details_parts.first}" : "Models disagree: #{details_parts.join(', ')}"

      # Pick the best reason from majority group
      majority_results = verdict_groups[majority_verdict] || results
      best_reason = majority_results.max_by { |r| r.reason_summary.to_s.length }&.reason_summary

      Result.new(
        verdict: majority_verdict,
        confidence_score: [mean_confidence - disagreement_penalty, 0].max.round(2),
        reason_summary: best_reason,
        model_results: model_results,
        disagreement_details: disagreement_details,
        unanimous: unanimous
      )
    end

    def compute_disagreement_penalty(results)
      verdicts = results.map(&:verdict).uniq
      return 0 if verdicts.one?

      if verdicts.size == 2
        pair_penalty(verdicts[0], verdicts[1])
      elsif verdicts.size >= 3
        0.25
      else
        0
      end
    end

    def pair_penalty(a, b)
      idx_a = VERDICT_ORDER.index(a.to_s) || 4
      idx_b = VERDICT_ORDER.index(b.to_s) || 4
      distance = (idx_a - idx_b).abs

      case distance
      when 0 then 0
      when 1 then 0.08  # adjacent (supported↔mixed, mixed↔disputed)
      else 0.15          # opposed (supported↔disputed, etc.)
      end
    end

    LLM_TIMEOUT_SECONDS = ENV.fetch("LLM_TIMEOUT_SECONDS", 120).to_i

    def ask_model(model:, claim:, evidence_packet:, prompt_text:, packet_fingerprint:, investigation:, claim_assessment:)
      if investigation && (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: packet_fingerprint, model_id: model))
        return parse_response(cached.response_json)
      end

      interaction = create_interaction(
        investigation:, claim_assessment:, model:, prompt_text:, packet_fingerprint:
      )

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(LLM_TIMEOUT_SECONDS) do
        RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)
          .with_instructions(system_prompt)
          .with_schema(response_schema)
          .ask(prompt_text)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(response.content.to_s)

      complete_interaction(interaction, response:, payload:, elapsed_ms:) if interaction

      Result.new(
        verdict: payload.fetch("verdict"),
        confidence_score: payload.fetch("confidence_score").to_f.clamp(0, 0.97),
        reason_summary: payload.fetch("reason_summary")
      )
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      raise
    end

    def create_interaction(investigation:, claim_assessment:, model:, prompt_text:, packet_fingerprint:)
      return nil unless investigation

      LlmInteraction.create!(
        investigation:,
        claim_assessment:,
        interaction_type: :assessment,
        model_id: model,
        prompt_text:,
        evidence_packet_fingerprint: packet_fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create LLM interaction record: #{e.message}")
      nil
    end

    def complete_interaction(interaction, response:, payload:, elapsed_ms:)
      interaction.update!(
        response_text: response.content.to_s,
        response_json: payload,
        status: :completed,
        latency_ms: elapsed_ms,
        prompt_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
        completion_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to update LLM interaction record: #{e.message}")
    end

    def fail_interaction(interaction, error)
      interaction.update!(
        status: :failed,
        error_class: error.class.name,
        error_message: error.message.truncate(500)
      )
    rescue StandardError
      nil
    end

    def parse_response(json)
      Result.new(
        verdict: json.fetch("verdict"),
        confidence_score: json.fetch("confidence_score").to_f.clamp(0, 0.97),
        reason_summary: json.fetch("reason_summary")
      )
    end

    def build_prompt(claim:, evidence_packet:)
      {
        claim: claim.canonical_text,
        claim_kind: claim.claim_kind,
        checkability_status: claim.checkability_status,
        entities: claim.entities_json,
        time_scope: claim.time_scope,
        evidence_count: evidence_packet.size,
        evidence: evidence_packet
      }.to_json
    end

    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE % { locale_name: LOCALE_NAMES.fetch(I18n.locale, "English") }
    end

    def response_schema
      {
        name: "claim_assessment",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            verdict: {
              type: "string",
              enum: %w[supported disputed mixed needs_more_evidence not_checkable]
            },
            confidence_score: {
              type: "number"
            },
            reason_summary: {
              type: "string"
            }
          },
          required: %w[verdict confidence_score reason_summary]
        }
      }
    end
  end
end
