module Analyzers
  # Detects statistical deception: numbers that are technically correct but
  # deliberately misleading.
  #
  # An article can cite real statistics and still deceive the reader through
  # selective framing: presenting percentages without absolute numbers, cherry-picking
  # baseline periods, comparing incomparable scales, or changing denominators
  # mid-argument without disclosure.
  #
  # Phase 1 (heuristic): Regex-extract all numbers, percentages, multipliers, and
  #          comparisons from the article body. Flag patterns like percentages without
  #          absolute context, percentage-of-percentage, and comparisons without baselines.
  # Phase 2 (LLM): Identify specific deception types with severity, excerpts, and
  #          corrective context showing what honest presentation would look like.
  class StatisticalDeceptionDetector
    Deception = Struct.new(:type, :excerpt, :severity, :explanation, :corrective_context, keyword_init: true)

    Result = Struct.new(
      :deceptions,
      :statistical_integrity_score,
      :summary,
      keyword_init: true
    )

    MAX_DECEPTIONS = 8

    DECEPTION_TYPES = %w[
      cherry_picked_baseline
      relative_absolute_confusion
      survivorship_bias
      scale_manipulation
      denominator_games
      missing_base
    ].freeze

    SEVERITIES = %w[low medium high].freeze

    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a statistical literacy expert for a fact-checking system. Your job is to identify
      numbers and statistics in articles that are technically correct but presented in a way
      that misleads the reader.

      Statistical deception is one of the most effective misinformation techniques because the
      numbers are real — only the framing is dishonest. Common patterns:

      1. CHERRY-PICKED BASELINE (cherry_picked_baseline): Choosing a start date or comparison
         period that exaggerates a trend. Example: "Crime up 40%%" by comparing to the
         historically lowest year instead of a 5-year average.

      2. RELATIVE-ABSOLUTE CONFUSION (relative_absolute_confusion): Using percentages when
         absolute numbers tell a different story, or vice versa. Example: "Risk doubles!"
         when the base rate goes from 1-in-a-million to 2-in-a-million.

      3. SURVIVORSHIP BIAS (survivorship_bias): Only citing cases, companies, countries, or
         studies that survived some filter while ignoring those that didn't. Example: citing
         successful startups that took risks while ignoring the 90%% that failed the same way.

      4. SCALE MANIPULATION (scale_manipulation): Comparing numbers from incomparable scales
         or contexts. Example: comparing raw totals between countries of vastly different
         populations without per-capita adjustment.

      5. DENOMINATOR GAMES (denominator_games): Changing what's being measured mid-argument
         without disclosing the switch. Example: switching between "percentage of GDP" and
         "absolute spending" within the same argument to make both increases and decreases
         look alarming.

      6. MISSING BASE (missing_base): Presenting percentages, multiples, or ratios without
         stating the base number. Example: "Sales grew 300%%!" without saying they went from
         2 to 8 units.

      You will receive the article's title, excerpt, and any statistical patterns already
      identified by heuristic analysis.

      For each deception found, provide:
      - type: One of: cherry_picked_baseline, relative_absolute_confusion, survivorship_bias,
              scale_manipulation, denominator_games, missing_base
      - excerpt: The exact passage from the article containing the deception (verbatim quote)
      - severity: "low", "medium", or "high"
      - explanation: Why this is misleading (1-2 sentences)
      - corrective_context: What an honest presentation would look like (1-2 sentences)

      Rate overall statistical_integrity_score (0.0-1.0) where:
      - 1.0 = all statistics properly contextualized with bases, comparisons, and caveats
      - 0.7+ = minor omissions that don't materially mislead
      - 0.4-0.7 = significant deceptions that could change reader conclusions
      - <0.4 = systematic statistical manipulation throughout the article

      IMPORTANT: Write explanation, corrective_context, and summary in %{locale_name}.
      Only flag genuine deceptions — do not flag statistics that are properly contextualized.
      If the article has no statistics or all statistics are honestly presented, return an
      empty deceptions array and score 1.0.


      CRITICAL — NO HALLUCINATION: Only reference URLs, sources, claims, quotes, and data
      that are EXPLICITLY present in the input provided to you. Do not invent, guess, or
      fabricate any URL, source name, statistic, quote, or claim. If you cannot verify
      something from the provided text, mark it as "unverifiable" — never fill in details
      you are unsure about. Every excerpt must be traceable to the provided input.

      Return strict JSON matching the schema.
    PROMPT

    # ── Heuristic patterns ──

    # Matches percentages: 45%, 3.2%, 300%
    PERCENTAGE_RE = /\b(\d+(?:[.,]\d+)?)\s*%/.freeze

    # Matches multipliers: 3x, 10x, 2.5x
    MULTIPLIER_RE = /\b(\d+(?:[.,]\d+)?)\s*[xX]\b/.freeze

    # Matches comparisons without clear baselines: "increased by", "grew", "rose", "fell"
    COMPARISON_RE = /\b(?:increas|decreas|gr[eo]w|rose|fell|drop|surg|plung|spiked?|doubled?|tripled?|halved?)\w*\b/i.freeze

    # Matches absolute numbers near percentages (context check)
    ABSOLUTE_NEAR_PCT_RE = /(\d{1,3}(?:[.,]\d{3})*(?:\.\d+)?)\s+.*?\b(\d+(?:[.,]\d+)?)\s*%|(\d+(?:[.,]\d+)?)\s*%\s+.*?(\d{1,3}(?:[.,]\d{3})*(?:\.\d+)?)/m.freeze

    # Matches percentage of percentage: "X% of the Y%"
    PCT_OF_PCT_RE = /\d+(?:[.,]\d+)?\s*%\s+(?:of|d[aeo]s?|dos?)\s+(?:the\s+)?\d+(?:[.,]\d+)?\s*%/i.freeze

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      article = @investigation.root_article
      return empty_result unless article&.body_text.present?

      body = article.body_text.to_s

      # Phase 1: Heuristic extraction
      heuristic_data = heuristic_analysis(body)

      # Phase 2: LLM analysis
      llm_result = identify_deceptions(article, heuristic_data)
      return heuristic_fallback(heuristic_data) unless llm_result

      deceptions = Array(llm_result[:deceptions]).first(MAX_DECEPTIONS).map do |d|
        Deception.new(
          type: d[:type].to_s,
          excerpt: d[:excerpt].to_s,
          severity: SEVERITIES.include?(d[:severity].to_s) ? d[:severity].to_s : "low",
          explanation: d[:explanation].to_s,
          corrective_context: d[:corrective_context].to_s
        )
      end

      integrity = llm_result[:statistical_integrity_score].to_f.clamp(0, 1).round(2)

      Result.new(
        deceptions: deceptions,
        statistical_integrity_score: integrity,
        summary: llm_result[:summary].to_s
      )
    end

    private

    # ── Phase 1: Heuristic analysis ──

    def heuristic_analysis(body)
      percentages = body.scan(PERCENTAGE_RE).flatten
      multipliers = body.scan(MULTIPLIER_RE).flatten
      comparisons = body.scan(COMPARISON_RE)
      pct_of_pct = body.scan(PCT_OF_PCT_RE)

      # Check how many percentages have absolute numbers nearby (within ~100 chars)
      contextualized = 0
      uncontextualized = 0

      # Split body into sentences for proximity analysis
      sentences = body.split(/[.!?]+/)
      sentences.each do |sentence|
        pct_matches = sentence.scan(PERCENTAGE_RE)
        next if pct_matches.empty?

        # Check if sentence also contains an absolute number (not a percentage)
        has_absolute = sentence.match?(/\b\d{2,}(?:[.,]\d{3})*\b/) &&
          sentence.gsub(PERCENTAGE_RE, "").match?(/\b\d{2,}(?:[.,]\d{3})*\b/)

        if has_absolute
          contextualized += pct_matches.size
        else
          uncontextualized += pct_matches.size
        end
      end

      {
        total_percentages: percentages.size,
        contextualized_percentages: contextualized,
        uncontextualized_percentages: uncontextualized,
        multiplier_count: multipliers.size,
        comparison_count: comparisons.size,
        pct_of_pct_count: pct_of_pct.size,
        has_statistics: percentages.any? || multipliers.any?
      }
    end

    # ── Phase 2: LLM deception identification ──

    def identify_deceptions(article, heuristic_data)
      return nil unless llm_available?

      prompt = build_prompt(article, heuristic_data)
      fingerprint = Digest::SHA256.hexdigest(prompt)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return cached.response_json&.deep_symbolize_keys
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

      payload.deep_symbolize_keys
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Statistical deception LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article, heuristic_data)
      {
        article_title: article.title,
        article_excerpt: article.body_text.to_s.truncate(3000),
        article_host: article.host,
        heuristic_findings: {
          total_percentages: heuristic_data[:total_percentages],
          uncontextualized_percentages: heuristic_data[:uncontextualized_percentages],
          multiplier_count: heuristic_data[:multiplier_count],
          comparison_count: heuristic_data[:comparison_count],
          pct_of_pct_count: heuristic_data[:pct_of_pct_count]
        }
      }.to_json
    end

    def response_schema
      {
        name: "statistical_deception_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            deceptions: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  type: { type: "string", enum: DECEPTION_TYPES },
                  excerpt: { type: "string" },
                  severity: { type: "string", enum: SEVERITIES },
                  explanation: { type: "string" },
                  corrective_context: { type: "string" }
                },
                required: %w[type excerpt severity explanation corrective_context]
              }
            },
            statistical_integrity_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[deceptions statistical_integrity_score summary]
        }
      }
    end

    # ── Heuristic fallback ──

    def heuristic_fallback(heuristic_data)
      return no_statistics_result unless heuristic_data[:has_statistics]

      total = heuristic_data[:total_percentages]
      uncontextualized = heuristic_data[:uncontextualized_percentages]

      # No percentages found but has multipliers/comparisons — mild concern
      if total == 0
        integrity = 0.8
        deceptions = []
        if heuristic_data[:multiplier_count] > 0
          deceptions << Deception.new(
            type: "missing_base",
            excerpt: I18n.t("heuristic_fallbacks.statistical_deception.multiplier_excerpt"),
            severity: "low",
            explanation: I18n.t("heuristic_fallbacks.statistical_deception.multiplier_explanation"),
            corrective_context: I18n.t("heuristic_fallbacks.statistical_deception.multiplier_corrective")
          )
          integrity = 0.7
        end

        return Result.new(
          deceptions: deceptions,
          statistical_integrity_score: integrity,
          summary: I18n.t("heuristic_fallbacks.statistical_deception.no_percentages_summary")
        )
      end

      # Score = proportion of uncontextualized percentages (inverted for integrity)
      raw_score = uncontextualized.to_f / total
      integrity = (1.0 - raw_score).clamp(0, 1).round(2)

      deceptions = []

      if uncontextualized > 0
        deceptions << Deception.new(
          type: "missing_base",
          excerpt: I18n.t("heuristic_fallbacks.statistical_deception.missing_base_excerpt", count: uncontextualized),
          severity: uncontextualized > 3 ? "high" : (uncontextualized > 1 ? "medium" : "low"),
          explanation: I18n.t("heuristic_fallbacks.statistical_deception.missing_base_explanation"),
          corrective_context: I18n.t("heuristic_fallbacks.statistical_deception.missing_base_corrective")
        )
      end

      if heuristic_data[:pct_of_pct_count] > 0
        deceptions << Deception.new(
          type: "denominator_games",
          excerpt: I18n.t("heuristic_fallbacks.statistical_deception.pct_of_pct_excerpt"),
          severity: "medium",
          explanation: I18n.t("heuristic_fallbacks.statistical_deception.pct_of_pct_explanation"),
          corrective_context: I18n.t("heuristic_fallbacks.statistical_deception.pct_of_pct_corrective")
        )
        integrity = [ integrity - 0.1, 0 ].max.round(2)
      end

      Result.new(
        deceptions: deceptions,
        statistical_integrity_score: integrity,
        summary: I18n.t("heuristic_fallbacks.statistical_deception.heuristic_summary",
          uncontextualized: uncontextualized, total: total)
      )
    end

    def no_statistics_result
      Result.new(
        deceptions: [],
        statistical_integrity_score: 1.0,
        summary: I18n.t("heuristic_fallbacks.statistical_deception.no_statistics")
      )
    end

    def empty_result
      Result.new(deceptions: [], statistical_integrity_score: 1.0, summary: I18n.t("heuristic_fallbacks.statistical_deception.no_analysis"))
    end

    # ── LLM helpers ──

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :statistical_deception,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create statistical deception interaction: #{e.message}")
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
      Rails.logger.warn("Failed to update statistical deception interaction: #{e.message}")
    end

    def fail_interaction(interaction, error)
      return unless interaction
      interaction.update!(status: :failed, error_class: error.class.name, error_message: error.message.truncate(500))
    rescue StandardError
      nil
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE
        .gsub("%{locale_name}", LOCALE_NAMES.fetch(I18n.locale, "English"))
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
