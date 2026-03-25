module Investigations
  class GenerateSummary
    Result = Struct.new(:conclusion, :strengths, :weaknesses, :overall_quality, keyword_init: true)

    QUALITY_VALUES = %w[strong mixed weak insufficient].freeze

    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are an editorial quality analyst for a fact-checking system. You produce a concise
      executive summary of an investigation into a news article.

      You will receive:
      - The article title and excerpt
      - All assessed claims with their verdicts, confidence scores, and reasons
      - Scores for headline bait, independence, authority, and rhetorical analysis
      - Contextual gap analysis: unaddressed questions and counter-evidence found via web search

      Your job is to synthesize ALL of these findings into:
      1. A conclusion paragraph: what the article got right, what it omits, and overall quality
      2. Strengths: specific things the article does well (well-sourced claims, primary evidence, etc.)
      3. Weaknesses: specific problems — INCLUDING contextual gaps. An article that is factually
         correct but omits critical context that would change the reader's conclusion is WEAK,
         not strong. Factor in:
         - Missing counter-evidence found by web search
         - Scope mismatches (citing foreign data for local conclusions)
         - Omitted distributional effects, historical precedents, or institutional context
      4. An overall_quality rating: "strong", "mixed", "weak", or "insufficient"

      Rating guide:
      - strong: Claims supported, relevant context addressed, no major omissions
      - mixed: Claims may be supported but significant context is missing or scope is questionable
      - weak: Major contextual gaps, misleading through omission, or most claims unsupported
      - insufficient: Not enough evidence to assess meaningfully

      CRITICAL: An article where every claim is technically true but critical counter-evidence
      is omitted should be rated "mixed" at best, "weak" if the omissions are severe. Factual
      accuracy alone does not make an article trustworthy — completeness matters.

      IMPORTANT: Write the conclusion, strengths, and weaknesses texts in %{locale_name}.
      The overall_quality field must always use the English enum values above.

      Return strict JSON matching the schema.
    PROMPT

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      llm_result = run_llm_analysis
      return llm_result if llm_result

      heuristic_fallback
    end

    private

    def assessed_claims
      @assessed_claims ||= @investigation.claim_assessments
        .includes(:claim)
        .where.not(verdict: "pending")
        .order(confidence_score: :desc)
    end

    def run_llm_analysis
      return nil unless llm_available?
      return heuristic_fallback unless assessed_claims.any?

      prompt = build_prompt
      fingerprint = Digest::SHA256.hexdigest(prompt)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return parse_response(cached.response_json)
      end

      interaction = create_interaction(model, prompt, fingerprint)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)
          .with_instructions(system_prompt)
          .with_schema(response_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_response(payload)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Investigation summary LLM failed: #{e.message}")
      nil
    end

    def build_prompt
      article = @investigation.root_article
      claims_context = assessed_claims.map do |assessment|
        {
          claim: assessment.claim.canonical_text,
          verdict: assessment.verdict,
          confidence: assessment.confidence_score.to_f,
          authority_score: assessment.authority_score.to_f,
          independence_score: assessment.independence_score.to_f,
          reason: assessment.reason_summary
        }
      end

      rhetorical = @investigation.rhetorical_analysis || {}
      contextual = @investigation.contextual_gaps || {}

      gaps_context = Array(contextual["gaps"]).map do |gap|
        {
          question: gap["question"],
          relevance: gap["relevance"],
          evidence_found: Array(gap["search_results"]).map { |sr| { title: sr["title"], snippet: sr["snippet"] } }
        }
      end

      {
        article_title: article&.title,
        article_excerpt: article&.excerpt.to_s.truncate(500),
        headline_bait_score: @investigation.headline_bait_score.to_f,
        overall_confidence_score: @investigation.overall_confidence_score.to_f,
        claims: claims_context,
        rhetorical_summary: rhetorical["summary"],
        narrative_bias_score: rhetorical["narrative_bias_score"].to_f,
        fallacy_count: Array(rhetorical["fallacies"]).size,
        contextual_gaps: {
          completeness_score: contextual["completeness_score"].to_f,
          summary: contextual["summary"],
          gaps: gaps_context
        }
      }.to_json
    end

    def response_schema
      {
        name: "investigation_summary",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            conclusion: { type: "string" },
            strengths: { type: "array", items: { type: "string" } },
            weaknesses: { type: "array", items: { type: "string" } },
            overall_quality: { type: "string", enum: QUALITY_VALUES }
          },
          required: %w[conclusion strengths weaknesses overall_quality]
        }
      }
    end

    def parse_response(payload)
      quality = payload["overall_quality"].to_s
      quality = "insufficient" unless QUALITY_VALUES.include?(quality)

      Result.new(
        conclusion: payload["conclusion"].to_s,
        strengths: Array(payload["strengths"]),
        weaknesses: Array(payload["weaknesses"]),
        overall_quality: quality
      )
    end

    def heuristic_fallback
      return Result.new(conclusion: "", strengths: [], weaknesses: [], overall_quality: "insufficient") unless assessed_claims.any?

      supported = assessed_claims.select { |a| a.verdict == "supported" }
      disputed = assessed_claims.select { |a| a.verdict == "disputed" }
      needs_evidence = assessed_claims.select { |a| a.verdict == "needs_more_evidence" }
      avg_confidence = @investigation.overall_confidence_score.to_f

      strengths = []
      weaknesses = []

      strengths << I18n.t("heuristic_fallbacks.summary.supported_claims", count: supported.size) if supported.any?
      weaknesses << I18n.t("heuristic_fallbacks.summary.disputed_claims", count: disputed.size) if disputed.any?
      weaknesses << I18n.t("heuristic_fallbacks.summary.needs_evidence_claims", count: needs_evidence.size) if needs_evidence.any?

      if @investigation.headline_bait_score.to_f >= 0.7
        weaknesses << I18n.t("heuristic_fallbacks.summary.high_headline_bait")
      end

      # Factor in contextual gaps
      contextual = @investigation.contextual_gaps || {}
      gap_count = Array(contextual["gaps"]).size
      completeness = contextual["completeness_score"].to_f

      if gap_count > 0
        weaknesses << I18n.t("heuristic_fallbacks.summary.contextual_gaps_found", count: gap_count)
      end

      quality = if disputed.size > supported.size
        "weak"
      elsif completeness > 0 && completeness < 0.4
        "weak"
      elsif avg_confidence >= 0.6 && supported.size > disputed.size && completeness >= 0.7
        "strong"
      elsif avg_confidence >= 0.6 && supported.size > disputed.size
        "mixed" # downgrade from strong due to contextual gaps
      elsif assessed_claims.size <= 1 && needs_evidence.any?
        "insufficient"
      else
        "mixed"
      end

      conclusion = I18n.t("heuristic_fallbacks.summary.conclusion",
        total: assessed_claims.size,
        supported: supported.size,
        disputed: disputed.size,
        needs_evidence: needs_evidence.size
      )

      Result.new(conclusion:, strengths:, weaknesses:, overall_quality: quality)
    end

    # ── LLM interaction helpers ──

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :investigation_summary,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create summary interaction: #{e.message}")
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
    rescue StandardError => e
      Rails.logger.warn("Failed to update summary interaction: #{e.message}")
    end

    def fail_interaction(interaction, error)
      return unless interaction
      interaction.update!(status: :failed, error_class: error.class.name, error_message: error.message.truncate(500))
    rescue StandardError
      nil
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE.gsub("%{locale_name}", LOCALE_NAMES.fetch(I18n.locale, "English"))
    end

    def llm_available?
      defined?(RubyLLM) && ENV["OPENROUTER_API_KEY"].present?
    end

    def primary_model
      Array(Rails.application.config.x.frank_investigator.openrouter_models).first || "anthropic/claude-sonnet-4-6"
    end

    def llm_timeout
      ENV.fetch("LLM_TIMEOUT_SECONDS", 120).to_i
    end

    def unwrap_json(content)
      text = content.to_s.strip
      text = text.sub(/\A```(?:json)?\s*\n?/, "").sub(/\n?\s*```\z/, "") if text.start_with?("```")
      text
    end
  end
end
