module Analyzers
  # Holistic emotional manipulation scorer that runs LAST among analyzers
  # (before GenerateSummary). It consumes ALL other analyzer results to produce
  # a final manipulation score.
  #
  # KEY INSIGHT: High emotion + high evidence = legitimate passionate journalism.
  # High emotion + low evidence + high deception scores = manipulation.
  #
  # Phase 1 (heuristic): Scan article body for emotional language patterns
  #   and compute emotional_density = emotional_words / total_words.
  #
  # Phase 2 (LLM): Given article body AND all previous analyzer scores,
  #   produce emotional_temperature, evidence_density, manipulation_score,
  #   dominant_emotions, and contributing_factors.
  class EmotionalManipulationScorer
    include LlmHelpers

    Result = Struct.new(
      :emotional_temperature,
      :evidence_density,
      :manipulation_score,
      :dominant_emotions,
      :contributing_factors,
      :summary,
      keyword_init: true
    )

    # ── Emotional word dictionaries ──

    FEAR_WORDS = %w[
      danger crisis threat catastrophe disaster emergency alarm panic terror
      perigo crise ameaça catástrofe desastre emergência alarme pânico terror
    ].freeze

    OUTRAGE_WORDS = %w[
      scandal corruption betrayal abuse outrage disgrace shame fraud
      escândalo corrupção traição abuso ultraje desgraça vergonha fraude
    ].freeze

    URGENCY_WORDS = %w[
      immediately urgently now critical crucial vital essential
      imediatamente urgentemente agora crítico crucial vital essencial
    ].freeze

    ABSOLUTIST_WORDS = %w[
      always never all none every nobody everyone nothing
      sempre nunca todos nenhum toda ninguém tudo nada
    ].freeze

    ALL_EMOTIONAL_WORDS = (FEAR_WORDS + OUTRAGE_WORDS + URGENCY_WORDS + ABSOLUTIST_WORDS).to_set.freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are an emotional manipulation analyst for a fact-checking system. Your job is to
      assess whether an article uses emotional appeals to compensate for weak evidence, or
      whether its emotional tone is proportionate to well-supported claims.

      HIGH EMOTION + HIGH EVIDENCE = legitimate passionate journalism (low manipulation score).
      HIGH EMOTION + LOW EVIDENCE + HIGH DECEPTION = manipulation (high manipulation score).
      LOW EMOTION + HIGH EVIDENCE = dispassionate reporting (low manipulation score).
      LOW EMOTION + LOW EVIDENCE = lazy reporting, not manipulation (moderate manipulation score).

      You will receive:
      1. The article text (truncated)
      2. Scores from all previous analyzers:
         - rhetorical narrative_bias_score (0-1): how biased the narrative framing is
         - source misrepresentation_score (0-1): how much sources are misrepresented
         - temporal integrity_score (0-1): how well temporal context is preserved (1 = good)
         - statistical integrity_score (0-1): how honest the statistics are (1 = good)
         - quotation integrity_score (0-1): how faithfully quotes are used (1 = good)
         - authority laundering_score (0-1): how much false authority is invoked
         - contextual completeness_score (0-1): how complete the context is (1 = good)
         - coordinated narrative coordination_score (0-1): how coordinated with other outlets
         - headline_bait_score (0-1): how baiting the headline is
      3. Heuristic emotional_density from word pattern scanning

      Produce:
      - emotional_temperature (0.0-1.0): how emotionally charged the article is overall
      - evidence_density (0.0-1.0): ratio of evidence-based claims to emotional appeals
        (1.0 = all evidence, 0.0 = all emotion)
      - manipulation_score (0.0-1.0): overall manipulation assessment combining emotional
        temperature with evidence gaps and deception indicators from other analyzers
      - dominant_emotions: array of emotion labels present (e.g., "fear", "outrage",
        "urgency", "contempt", "hope", "indignation", "pity", "anxiety")
      - contributing_factors: array of objects, each with:
        - factor (string): what contributes to the score (e.g., "high emotional density
          with low evidence", "headline bait combined with outrage framing")
        - weight (number 0.0-1.0): how much this factor contributes
      - summary: 2-3 sentence assessment of emotional manipulation risk

      CALIBRATION: Most articles have some emotional language — this is normal and does not
      make them manipulative. Manipulation requires emotional appeals that SUBSTITUTE for
      evidence, not emotional language that ACCOMPANIES evidence. An opinion piece with strong
      language and solid citations is passionate journalism, not manipulation. Only score
      manipulation_score above 0.5 when there is a clear pattern of emotion compensating for
      missing evidence or amplifying deception detected by other analyzers.

      IMPORTANT: Write the summary, dominant_emotions labels, and contributing_factors
      descriptions in %{locale_name}.


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
      article = @investigation.root_article
      return empty_result unless article&.body_text.present?

      # Phase 1: Heuristic emotional density scan
      @emotional_density = compute_emotional_density(article.body_text)

      # Phase 2: LLM holistic scoring
      llm_result = score_via_llm(article)
      return heuristic_fallback(article) unless llm_result

      Result.new(
        emotional_temperature: llm_result[:emotional_temperature].to_f.clamp(0, 1).round(2),
        evidence_density: llm_result[:evidence_density].to_f.clamp(0, 1).round(2),
        manipulation_score: llm_result[:manipulation_score].to_f.clamp(0, 1).round(2),
        dominant_emotions: Array(llm_result[:dominant_emotions]).map(&:to_s),
        contributing_factors: normalize_factors(llm_result[:contributing_factors]),
        summary: llm_result[:summary].to_s
      )
    end

    private

    # ── Phase 1: Heuristic emotional density ──

    def compute_emotional_density(body_text)
      words = body_text.downcase.scan(/[\p{L}]+/)
      return 0.0 if words.empty?

      emotional_count = words.count { |w| ALL_EMOTIONAL_WORDS.include?(w) }
      (emotional_count.to_f / words.size).round(4)
    end

    # ── Phase 2: LLM holistic scoring ──

    def score_via_llm(article)
      return nil unless llm_available?

      prompt = build_prompt(article)
      fingerprint = Digest::SHA256.hexdigest(prompt)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return cached.response_json&.deep_symbolize_keys
      end

      interaction = create_interaction(model, prompt, fingerprint)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        llm_chat(model:)
          .with_instructions(system_prompt)
          .with_schema(response_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      payload.deep_symbolize_keys
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Emotional manipulation scoring LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      rhetorical = @investigation.rhetorical_analysis || {}
      source_misrep = @investigation.source_misrepresentation || {}
      temporal = @investigation.temporal_manipulation || {}
      statistical = @investigation.statistical_deception || {}
      quotation = @investigation.selective_quotation || {}
      authority = @investigation.authority_laundering || {}
      contextual = @investigation.contextual_gaps || {}
      coordinated = @investigation.coordinated_narrative || {}

      {
        article_title: article.title,
        article_excerpt: article.body_text.to_s.truncate(4000),
        article_host: article.host,
        heuristic_emotional_density: @emotional_density,
        analyzer_scores: {
          narrative_bias_score: rhetorical["narrative_bias_score"].to_f,
          misrepresentation_score: source_misrep["misrepresentation_score"].to_f,
          temporal_integrity_score: temporal["temporal_integrity_score"].to_f,
          statistical_integrity_score: statistical["statistical_integrity_score"].to_f,
          quotation_integrity_score: quotation["quotation_integrity_score"].to_f,
          laundering_score: authority["laundering_score"].to_f,
          completeness_score: contextual["completeness_score"].to_f,
          coordination_score: coordinated["coordination_score"].to_f,
          headline_bait_score: @investigation.headline_bait_score.to_f
        }
      }.to_json
    end

    def response_schema
      {
        name: "emotional_manipulation_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            emotional_temperature: { type: "number" },
            evidence_density: { type: "number" },
            manipulation_score: { type: "number" },
            dominant_emotions: {
              type: "array",
              items: { type: "string" }
            },
            contributing_factors: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  factor: { type: "string" },
                  weight: { type: "number" }
                },
                required: %w[factor weight]
              }
            },
            summary: { type: "string" }
          },
          required: %w[emotional_temperature evidence_density manipulation_score
                       dominant_emotions contributing_factors summary]
        }
      }
    end

    # ── Heuristic fallback ──

    def heuristic_fallback(_article)
      avg_confidence = average_claim_confidence
      # High emotional density + low evidence confidence = manipulation signal
      # High emotional density + high evidence confidence = passionate but grounded
      manipulation = (@emotional_density * (1.0 - avg_confidence)).clamp(0, 1).round(2)

      # Incorporate deception signals from other analyzers when available
      deception_boost = compute_deception_boost
      manipulation = [ manipulation + deception_boost, 1.0 ].min.round(2)

      dominant = detect_dominant_emotions_heuristic
      factors = []
      factors << { factor: "emotional_word_density", weight: @emotional_density.round(2) } if @emotional_density > 0.01
      factors << { factor: "low_claim_confidence", weight: (1.0 - avg_confidence).round(2) } if avg_confidence < 0.6
      factors << { factor: "deception_indicators", weight: deception_boost.round(2) } if deception_boost > 0.05

      Result.new(
        emotional_temperature: [ @emotional_density * 10, 1.0 ].min.round(2),
        evidence_density: avg_confidence.round(2),
        manipulation_score: manipulation,
        dominant_emotions: dominant,
        contributing_factors: factors,
        summary: I18n.t(
          "heuristic_fallbacks.emotional_manipulation.summary",
          density: (@emotional_density * 100).round(1),
          score: manipulation
        )
      )
    end

    def average_claim_confidence
      assessments = @investigation.claim_assessments.where.not(verdict: "pending")
      return 0.5 if assessments.empty?

      assessments.average(:confidence_score).to_f
    end

    def compute_deception_boost
      scores = []
      rhetorical = @investigation.rhetorical_analysis || {}
      scores << rhetorical["narrative_bias_score"].to_f if rhetorical["narrative_bias_score"]

      source_misrep = @investigation.source_misrepresentation || {}
      scores << source_misrep["misrepresentation_score"].to_f if source_misrep["misrepresentation_score"]

      authority = @investigation.authority_laundering || {}
      scores << authority["laundering_score"].to_f if authority["laundering_score"]

      coordinated = @investigation.coordinated_narrative || {}
      scores << coordinated["coordination_score"].to_f if coordinated["coordination_score"]

      scores << @investigation.headline_bait_score.to_f if @investigation.headline_bait_score.to_f > 0

      return 0.0 if scores.empty?
      # Average deception signal, scaled down so it's a boost not a replacement
      (scores.sum / scores.size * 0.3).round(4)
    end

    def detect_dominant_emotions_heuristic
      body = @investigation.root_article&.body_text.to_s.downcase
      emotions = []
      emotions << "fear" if FEAR_WORDS.any? { |w| body.include?(w) }
      emotions << "outrage" if OUTRAGE_WORDS.any? { |w| body.include?(w) }
      emotions << "urgency" if URGENCY_WORDS.any? { |w| body.include?(w) }
      emotions
    end

    def normalize_factors(raw_factors)
      Array(raw_factors).map do |f|
        {
          factor: f[:factor].to_s,
          weight: f[:weight].to_f.clamp(0, 1).round(2)
        }
      end
    end

    def empty_result
      Result.new(
        emotional_temperature: 0.0,
        evidence_density: 1.0,
        manipulation_score: 0.0,
        dominant_emotions: [],
        contributing_factors: [],
        summary: I18n.t("heuristic_fallbacks.emotional_manipulation.no_analysis")
      )
    end

    def interaction_type_name
      :emotional_manipulation
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE
        .gsub("%{locale_name}", locale_name)
    end
  end
end
