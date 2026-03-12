module Analyzers
  # Analyzes the rhetorical structure of an article against its assessed claims.
  #
  # Detects when an article presents factual data (especially high-confidence
  # supported claims) but then uses logical fallacies to reframe, undermine,
  # or redirect the reader toward a different narrative.
  #
  # Common patterns:
  # - "Data shows X, BUT [opinion implying the opposite]" (bait-and-pivot)
  # - "In my 30 years of experience..." (appeal to authority over data)
  # - Attributing cause to an unrelated actor (strawman / false cause)
  # - Presenting a strong claim then immediately undermining it with speculation
  class RhetoricalFallacyAnalyzer
    Result = Struct.new(
      :fallacies,
      :narrative_bias_score,
      :summary,
      keyword_init: true
    )

    Fallacy = Struct.new(
      :type,
      :severity,
      :excerpt,
      :explanation,
      :undermined_claim,
      keyword_init: true
    )

    FALLACY_TYPES = %w[
      bait_and_pivot
      appeal_to_authority
      false_cause
      strawman
      anecdote_over_data
      loaded_language
      false_dilemma
      slippery_slope
      ad_hominem
      cherry_picking
    ].freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a rhetorical structure analyst for a fact-checking system. You analyze
      how an article's writing structure relates to its factual claims.

      Your job is to detect logical fallacies and rhetorical manipulation — specifically
      when an article presents factual data but then uses rhetorical devices to undermine,
      reframe, or redirect the reader toward a narrative not supported by the evidence.

      For each fallacy detected, provide:
      - type: one of #{FALLACY_TYPES.join(', ')}
      - severity: low, medium, or high
      - excerpt: the exact passage from the article (quote it verbatim, max 200 chars)
      - explanation: why this is a fallacy and what narrative it pushes
      - undermined_claim_index: which claim (by index) it undermines, or null

      Fallacy definitions for this context:

      bait_and_pivot: Article states a fact (often with data) then immediately pivots with
      "but", "however", "yet" to an opinion or implication that contradicts or undermines
      the fact. Example: "Crime fell 5% this quarter, but the president still condones violence."

      appeal_to_authority: Invoking personal experience, credentials, or unnamed experts to
      override data. Example: "The Fed says inflation is down, but in my 30 years in finance,
      I know it will bounce back."

      false_cause: Attributing a causal relationship without evidence. Example: "Unemployment
      dropped, despite the government's disastrous policies" (implying the policies should
      have caused unemployment to rise).

      strawman: Misrepresenting a position to make it easier to attack. Example: "Supporters
      of the new law want to destroy small business" when the law is about tax brackets.

      anecdote_over_data: Using a single story or case to override statistical evidence.
      Example: "GDP grew 3%, but I talked to Maria who lost her job."

      loaded_language: Using emotionally charged words to bias the reader beyond what the
      facts support. Example: "The regime's GDP figures" instead of "government GDP data."

      false_dilemma: Presenting only two options when more exist. Example: "Either we accept
      these inflation numbers or admit the economy is in freefall."

      slippery_slope: Arguing that one event will inevitably lead to extreme consequences
      without evidence. Example: "If rates drop now, hyperinflation is guaranteed."

      ad_hominem: Attacking the source of data rather than the data itself. Example: "These
      numbers come from the same agency that got it wrong in 2008."

      cherry_picking: Selectively presenting data that supports a narrative while ignoring
      contradicting data that the article itself mentions.

      IMPORTANT rules:
      - Only flag clear, identifiable fallacies. Do NOT flag normal journalistic framing,
        legitimate expert analysis, or balanced reporting.
      - A journalist providing context is NOT a fallacy. A journalist contradicting their
        own article's data with opinion IS a fallacy.
      - Rate severity based on how much the fallacy undermines the factual claims:
        - high: directly contradicts a high-confidence claim to push a false narrative
        - medium: subtly reframes factual data through rhetorical devices
        - low: mild framing bias that doesn't fundamentally mislead
      - The narrative_bias_score (0.0-1.0) reflects overall rhetorical manipulation:
        0.0 = straight factual reporting, 1.0 = entirely rhetorical manipulation.
      - Return empty fallacies array if the article is straightforward reporting.

      IMPORTANT: The type and severity fields must always use the English enum values above.
      However, write the explanation, summary, and excerpt texts in %{locale_name}.

      Return strict JSON matching the schema.
    PROMPT

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      article = @investigation.root_article
      return empty_result unless article&.body_text.present?
      return empty_result unless assessed_claims.any?

      llm_result = run_llm_analysis(article)
      return heuristic_analysis(article) unless llm_result

      llm_result
    end

    private

    def assessed_claims
      @assessed_claims ||= @investigation.claim_assessments
        .includes(:claim)
        .where.not(verdict: "pending")
        .order(confidence_score: :desc)
    end

    def run_llm_analysis(article)
      return nil unless llm_available?

      prompt = build_prompt(article)
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

      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(response.content.to_s)
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_response(payload)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Rhetorical analysis LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      claims_context = assessed_claims.map.with_index do |assessment, i|
        {
          index: i,
          claim: assessment.claim.canonical_text,
          verdict: assessment.verdict,
          confidence: assessment.confidence_score.to_f,
          authority_score: assessment.authority_score.to_f,
          has_primary_evidence: assessment.evidence_items.any? { |e| e.article&.authority_tier == "primary" }
        }
      end

      {
        article_title: article.title,
        article_body: article.body_text.to_s.truncate(4000),
        article_source_kind: article.source_kind,
        assessed_claims: claims_context
      }.to_json
    end

    def response_schema
      {
        name: "rhetorical_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            fallacies: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  type: { type: "string", enum: FALLACY_TYPES },
                  severity: { type: "string", enum: %w[low medium high] },
                  excerpt: { type: "string" },
                  explanation: { type: "string" },
                  undermined_claim_index: { type: ["integer", "null"] }
                },
                required: %w[type severity excerpt explanation]
              }
            },
            narrative_bias_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[fallacies narrative_bias_score summary]
        }
      }
    end

    def parse_response(payload)
      fallacies = Array(payload["fallacies"]).map do |f|
        undermined = if f["undermined_claim_index"].is_a?(Integer) && assessed_claims[f["undermined_claim_index"]]
          assessed_claims[f["undermined_claim_index"]].claim.canonical_text
        end

        Fallacy.new(
          type: f["type"],
          severity: f["severity"],
          excerpt: f["excerpt"],
          explanation: f["explanation"],
          undermined_claim: undermined
        )
      end

      Result.new(
        fallacies: fallacies,
        narrative_bias_score: payload["narrative_bias_score"].to_f.clamp(0, 1).round(2),
        summary: payload["summary"].to_s
      )
    end

    # ── Heuristic fallback when LLM is unavailable ──

    PIVOT_PATTERNS = [
      /\b(data|statistics?|numbers?|figures?|report)\b.{0,80}\b(but|however|yet|nevertheless|despite|still)\b/im,
      /\b(fell|dropped|grew|increased|rose|declined|improved)\b.{0,80}\b(but|however|yet|still)\b/im,
      /\b(dados|estatísticas?|números|relatório)\b.{0,80}\b(mas|porém|contudo|entretanto|apesar)\b/im
    ].freeze

    AUTHORITY_APPEAL_PATTERNS = [
      /\bin my (\d+\s+)?years?\b/i,
      /\bas (a|an) (expert|economist|analyst|journalist|professor)\b/i,
      /\bin my (long\s+)?(career|experience)\b/i,
      /\bna minha (longa\s+)?(carreira|experiência)\b/i,
      /\bcomo (economista|analista|especialista|professor)\b/i
    ].freeze

    def heuristic_analysis(article)
      body = article.body_text.to_s
      fallacies = []

      # Detect bait-and-pivot
      PIVOT_PATTERNS.each do |pattern|
        match = body.match(pattern)
        if match
          fallacies << Fallacy.new(
            type: "bait_and_pivot",
            severity: "medium",
            excerpt: match[0].truncate(200),
            explanation: I18n.t("heuristic_fallbacks.bait_and_pivot_explanation")
          )
          break
        end
      end

      # Detect appeal to authority
      AUTHORITY_APPEAL_PATTERNS.each do |pattern|
        match = body.match(pattern)
        if match
          fallacies << Fallacy.new(
            type: "appeal_to_authority",
            severity: "low",
            excerpt: match[0].truncate(200),
            explanation: I18n.t("heuristic_fallbacks.appeal_to_authority_explanation")
          )
          break
        end
      end

      bias_score = [fallacies.size * 0.2, 0.6].min

      Result.new(
        fallacies: fallacies,
        narrative_bias_score: bias_score.round(2),
        summary: fallacies.any? ? I18n.t("heuristic_fallbacks.heuristic_summary", count: fallacies.size) : I18n.t("heuristic_fallbacks.no_issues")
      )
    end

    def empty_result
      Result.new(fallacies: [], narrative_bias_score: 0.0, summary: I18n.t("heuristic_fallbacks.no_analysis"))
    end

    # ── LLM interaction helpers ──

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :rhetorical_analysis,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create rhetorical analysis interaction: #{e.message}")
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
      Rails.logger.warn("Failed to update rhetorical analysis interaction: #{e.message}")
    end

    def fail_interaction(interaction, error)
      return unless interaction
      interaction.update!(status: :failed, error_class: error.class.name, error_message: error.message.truncate(500))
    rescue StandardError
      nil
    end

    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE % { locale_name: LOCALE_NAMES.fetch(I18n.locale, "English") }
    end

    def llm_available?
      defined?(RubyLLM) && ENV["OPENROUTER_API_KEY"].present?
    end

    def primary_model
      Array(Rails.application.config.x.frank_investigator.openrouter_models).first || "anthropic/claude-3.7-sonnet"
    end

    def llm_timeout
      ENV.fetch("LLM_TIMEOUT_SECONDS", 120).to_i
    end
  end
end
