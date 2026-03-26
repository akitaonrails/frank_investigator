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

      You will receive multiple analyzer scores. Your job is to synthesize them into a fair,
      calibrated assessment — not to find fault, but to accurately rate the article's quality.

      CALIBRATION PRINCIPLE: Every article has imperfections. Minor issues should not accumulate
      into a harsh verdict. The question is not "is this article perfect?" but "does this article
      deliberately mislead the reader?" Distinguish between:
      - NORMAL EDITORIAL CHOICES: some emotional language, incomplete context, unverified citations
        — this is standard journalism, not manipulation. Rate "strong" or "mixed".
      - DELIBERATE MANIPULATION: systematic omissions, fabricated citations, coordinated framing
        across outlets, statistical tricks designed to deceive. Rate "weak".
      - SEVERE CASES: coordinated campaigns with convergent omissions AND convergent fallacies,
        or articles with multiple high-severity deception signals. Rate "weak".

      Analyzer scores to consider (only flag those with SIGNIFICANT findings):
      - Claim verdicts and confidence scores
      - Headline bait, rhetorical fallacies, narrative bias
      - Contextual gaps: unaddressed questions and missing counter-evidence
      - Source misrepresentation: does the article accurately represent its citations?
      - Temporal manipulation: is old data presented as current?
      - Statistical deception: are numbers presented misleadingly?
      - Selective quotation: are quotes taken out of context?
      - Authority laundering: does the citation chain inflate low-authority sources?
      - Coordinated narrative: do multiple outlets share identical framing and omissions?
      - Emotional manipulation: emotional temperature vs evidence density

      Rating guide:
      - strong: Well-sourced claims, relevant context addressed, no significant deception signals.
        Minor imperfections (a few unverifiable citations, some emotional language) are acceptable.
      - mixed: Some claims supported but notable gaps or moderate deception signals. The article
        is not deliberately misleading but has significant shortcomings.
      - weak: Deliberate manipulation detected — major contextual omissions designed to mislead,
        systematic source misrepresentation, coordinated narrative campaign, or multiple high-severity
        deception signals working together. Reserve this for genuinely problematic articles.
      - insufficient: Not enough evidence to assess meaningfully.

      DO NOT rate "weak" just because several analyzers found minor issues. A score of 0.2 from
      five different analyzers does not equal one score of 1.0 — it means the article has normal
      imperfections. Rate "weak" only when there is clear evidence of intentional manipulation
      or severe quality failures.

      IMPORTANT: Write the conclusion, strengths, and weaknesses texts in %{locale_name}.
      The overall_quality field must always use the English enum values above.


      CRITICAL — NO HALLUCINATION: Only reference URLs, sources, claims, quotes, and data
      that are EXPLICITLY present in the input provided to you. Do not invent, guess, or
      fabricate any URL, source name, statistic, quote, or claim. If you cannot verify
      something from the provided text, mark it as "unverifiable" — never fill in details
      you are unsure about. Every excerpt must be traceable to the provided input.

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
        },
        coordinated_narrative: coordinated_narrative_context,
        source_misrepresentation: analyzer_score_context(:source_misrepresentation, :misrepresentation_score),
        temporal_manipulation: analyzer_score_context(:temporal_manipulation, :temporal_integrity_score),
        statistical_deception: analyzer_score_context(:statistical_deception, :statistical_integrity_score),
        selective_quotation: analyzer_score_context(:selective_quotation, :quotation_integrity_score),
        authority_laundering: analyzer_score_context(:authority_laundering, :laundering_score),
        emotional_manipulation: emotional_manipulation_context
      }.to_json
    end

    def analyzer_score_context(column, score_key)
      data = @investigation.public_send(column) || {}
      { score_key => data[score_key.to_s].to_f, summary: data["summary"] }
    end

    def emotional_manipulation_context
      data = @investigation.emotional_manipulation || {}
      {
        manipulation_score: data["manipulation_score"].to_f,
        emotional_temperature: data["emotional_temperature"].to_f,
        evidence_density: data["evidence_density"].to_f,
        dominant_emotions: Array(data["dominant_emotions"]),
        summary: data["summary"]
      }
    end

    def coordinated_narrative_context
      coordinated = @investigation.coordinated_narrative || {}
      {
        coordination_score: coordinated["coordination_score"].to_f,
        pattern_summary: coordinated["pattern_summary"],
        convergent_framing: Array(coordinated["convergent_framing"]),
        convergent_omissions: Array(coordinated["convergent_omissions"]),
        similar_outlets_count: Array(coordinated["similar_coverage"]).size
      }
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

      # Factor in coordinated narrative
      coordinated = @investigation.coordinated_narrative || {}
      coordination_score = coordinated["coordination_score"].to_f

      if coordination_score >= 0.5
        weaknesses << I18n.t("heuristic_fallbacks.summary.coordinated_narrative_detected")
      end

      # Factor in new analyzers
      emotional = @investigation.emotional_manipulation || {}
      manipulation_score = emotional["manipulation_score"].to_f

      # Aggregate deception signals — only count signals above noise threshold (0.25).
      # Minor imperfections in honest journalism should not accumulate into a false
      # "weak" rating. Every article has some unverifiable citations, some emotional
      # language, some incomplete context — that's normal editorial work, not deception.
      noise_threshold = 0.25
      deception_signals = [
        (@investigation.source_misrepresentation || {})["misrepresentation_score"].to_f,
        1.0 - ((@investigation.temporal_manipulation || {})["temporal_integrity_score"] || 1.0).to_f,
        1.0 - ((@investigation.statistical_deception || {})["statistical_integrity_score"] || 1.0).to_f,
        1.0 - ((@investigation.selective_quotation || {})["quotation_integrity_score"] || 1.0).to_f,
        (@investigation.authority_laundering || {})["laundering_score"].to_f
      ].select { |s| s > noise_threshold }

      # Use max signal for "weak" determination — one serious finding matters more
      # than many minor ones. Use count of significant signals for "strong" gating.
      max_deception = deception_signals.max || 0.0
      significant_deception_count = deception_signals.size

      quality = if coordination_score >= 0.6 || manipulation_score >= 0.7
        "weak"
      elsif disputed.size > supported.size
        "weak"
      elsif completeness > 0 && completeness < 0.4
        "weak"
      elsif max_deception >= 0.6 || significant_deception_count >= 3
        "weak" # one severe deception or multiple moderate ones
      elsif avg_confidence >= 0.6 && supported.size > disputed.size && completeness >= 0.7 && coordination_score < 0.3 && significant_deception_count == 0
        "strong"
      elsif avg_confidence >= 0.6 && supported.size > disputed.size
        "mixed"
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
