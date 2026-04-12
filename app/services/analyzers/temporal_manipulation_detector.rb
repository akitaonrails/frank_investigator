module Analyzers
  # Detects temporal manipulation — the use of time as a tool to mislead readers.
  #
  # An article can cite real data and still deceive by presenting old numbers as
  # current, mixing events from different periods to imply causation, using present
  # tense for past events, or choosing a start date that exaggerates a trend.
  #
  # Phase 1 (heuristic): Scan article body for date patterns, years, and temporal
  #          words. Build a timeline of referenced periods.
  # Phase 2 (LLM): Given the article body and temporal references, identify
  #          specific manipulation patterns with severity ratings.
  class TemporalManipulationDetector
    include LlmHelpers

    Manipulation = Struct.new(:type, :excerpt, :referenced_period, :severity, :explanation, keyword_init: true)

    Result = Struct.new(
      :manipulations,
      :temporal_integrity_score,
      :summary,
      keyword_init: true
    )

    MAX_MANIPULATIONS = 8

    # Temporal words that signal time references in the article
    TEMPORAL_PATTERNS = %r{
      \b(\d{4})\b                                                                                              | # bare years
      \b(\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4})\b                                                                  | # dates like 01/03/2020
      \b(january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{4}\b     | # EN month+year
      \b(janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)\s+de\s+\d{4}\b | # PT month+year
      \b(last\s+year|this\s+year|last\s+month|last\s+decade|recently|currently|now|today)\b                   | # EN relative time
      \b(ano\s+passado|este\s+ano|mês\s+passado|última\s+década|recentemente|atualmente|agora|hoje)\b        | # PT relative time
      \b(since|from|between|during|in\s+the\s+past)\s+\d{4}\b                                                 | # EN range markers
      \b(desde|a\s+partir\s+de|entre|durante|nos\s+últimos)\s+\d{4}\b                                           # PT range markers
    }ix

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a temporal analysis expert for a fact-checking system. Your job is to detect
      how an article uses TIME to mislead readers — even when individual facts are accurate.

      Temporal manipulation patterns:

      1. STALE_DATA: Presenting old data without clearly dating it, letting the reader assume
         it is current. Example: "The unemployment rate is 12%%" when citing a 3-year-old figure
         while the current rate is 7%%.

      2. TIMELINE_MIXING: Juxtaposing events from different time periods to imply causation
         or correlation that doesn't exist. Example: "After Policy X was enacted [2015],
         crime rose sharply [citing 2020 data]" — omitting 5 years of other factors.

      3. IMPLICIT_RECENCY: Using present tense or "recently" for events that happened years ago,
         creating a false sense of immediacy. Example: "Studies show..." referencing a 2010 paper
         in a 2025 article without mentioning the date.

      4. SELECTIVE_TIMEFRAME: Choosing a start or end date that exaggerates a trend. Example:
         Starting a "crime increase" graph from a historic low point, or ending an "economic
         growth" chart just before a crash. Cherry-picking the window to support a narrative.

      You will receive:
      - The article body text
      - The article's publication date (if known)
      - Years and temporal references found in the text (heuristic pre-scan)

      For each manipulation found, provide:
      - type: one of "stale_data", "timeline_mixing", "implicit_recency", "selective_timeframe"
      - excerpt: the exact passage from the article (under 200 chars)
      - referenced_period: the time period being referenced (e.g., "2018", "2015-2019")
      - severity: "low", "medium", or "high"
      - explanation: why this is misleading (1-2 sentences)

      Rate temporal_integrity_score (0.0-1.0) where:
      - 1.0 = all temporal references are clearly dated and contextualized
      - 0.7+ = minor issues (slightly old data but clearly dated)
      - 0.4-0.7 = significant manipulation (undated old data, misleading timelines)
      - <0.4 = severe manipulation (multiple patterns, deliberately misleading temporal framing)

      IMPORTANT: Write explanations and summary in %{locale_name}.
      Only flag genuine manipulation — an article that clearly dates its references is fine
      even if it discusses old events.


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

      # Phase 1: Heuristic scan for temporal references
      @temporal_refs = extract_temporal_references(article.body_text)
      @publication_year = article.published_at&.year || article.created_at&.year

      # Phase 2: LLM analysis
      llm_result = analyze_with_llm(article)
      return heuristic_fallback(article) unless llm_result

      manipulations = parse_manipulations(llm_result)
      integrity = llm_result[:temporal_integrity_score].to_f.clamp(0, 1).round(2)

      Result.new(
        manipulations: manipulations,
        temporal_integrity_score: integrity,
        summary: llm_result[:summary].to_s
      )
    end

    private

    def extract_temporal_references(text)
      refs = { years: [], temporal_phrases: [] }

      text.scan(/\b((?:19|20)\d{2})\b/) do |match|
        year = match[0].to_i
        refs[:years] << year if year >= 1900 && year <= Date.current.year + 1
      end

      text.scan(TEMPORAL_PATTERNS) do |match|
        phrase = match.compact.first
        refs[:temporal_phrases] << phrase if phrase.present?
      end

      refs[:years] = refs[:years].uniq.sort
      refs[:temporal_phrases] = refs[:temporal_phrases].uniq
      refs
    end

    # ── Phase 2: LLM temporal analysis ──

    def analyze_with_llm(article)
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
      Rails.logger.warn("Temporal manipulation LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      {
        article_title: article.title,
        article_body: article.body_text.to_s.truncate(4000),
        article_host: article.host,
        publication_date: (article.published_at || article.created_at)&.iso8601,
        temporal_references: {
          years_mentioned: @temporal_refs[:years],
          temporal_phrases: @temporal_refs[:temporal_phrases].first(20)
        }
      }.to_json
    end

    def response_schema
      {
        name: "temporal_manipulation_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            manipulations: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  type: { type: "string", enum: %w[stale_data timeline_mixing implicit_recency selective_timeframe] },
                  excerpt: { type: "string" },
                  referenced_period: { type: "string" },
                  severity: { type: "string", enum: %w[low medium high] },
                  explanation: { type: "string" }
                },
                required: %w[type excerpt referenced_period severity explanation]
              }
            },
            temporal_integrity_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[manipulations temporal_integrity_score summary]
        }
      }
    end

    def parse_manipulations(llm_result)
      Array(llm_result[:manipulations]).first(MAX_MANIPULATIONS).map do |m|
        Manipulation.new(
          type: m[:type].to_s,
          excerpt: m[:excerpt].to_s,
          referenced_period: m[:referenced_period].to_s,
          severity: m[:severity].to_s,
          explanation: m[:explanation].to_s
        )
      end
    end

    # ── Heuristic fallback ──

    def heuristic_fallback(article)
      manipulations = []
      return empty_result unless @publication_year

      years = @temporal_refs[:years]
      stale_threshold = @publication_year - 2

      # Flag references to years more than 2 years before publication
      stale_years = years.select { |y| y <= stale_threshold && y >= 1990 }

      if stale_years.any?
        # Check if the article explicitly dates these references
        body = article.body_text.to_s.downcase
        undated_stale = stale_years.reject do |y|
          # If the year appears explicitly in the text, the reader can see it's old
          body.include?(y.to_s)
        end

        # Even explicitly dated old references are suspicious if many vs few recent
        recent_years = years.select { |y| y > stale_threshold }

        if undated_stale.any?
          manipulations << Manipulation.new(
            type: "stale_data",
            excerpt: I18n.t("heuristic_fallbacks.temporal_manipulation.undated_stale_excerpt",
                           years: undated_stale.join(", ")),
            referenced_period: "#{undated_stale.min}-#{undated_stale.max}",
            severity: undated_stale.size >= 3 ? "high" : "medium",
            explanation: I18n.t("heuristic_fallbacks.temporal_manipulation.undated_stale_explanation")
          )
        elsif stale_years.size > recent_years.size * 2 && stale_years.size >= 3
          manipulations << Manipulation.new(
            type: "stale_data",
            excerpt: I18n.t("heuristic_fallbacks.temporal_manipulation.predominantly_old_excerpt",
                           count: stale_years.size, total: years.size),
            referenced_period: "#{stale_years.min}-#{stale_years.max}",
            severity: "low",
            explanation: I18n.t("heuristic_fallbacks.temporal_manipulation.predominantly_old_explanation",
                               publication_year: @publication_year)
          )
        end
      end

      # Check for wide timeline spread (potential timeline_mixing)
      if years.size >= 3
        spread = years.max - years.min
        if spread >= 10
          manipulations << Manipulation.new(
            type: "timeline_mixing",
            excerpt: I18n.t("heuristic_fallbacks.temporal_manipulation.wide_spread_excerpt",
                           min: years.min, max: years.max),
            referenced_period: "#{years.min}-#{years.max}",
            severity: spread >= 20 ? "medium" : "low",
            explanation: I18n.t("heuristic_fallbacks.temporal_manipulation.wide_spread_explanation",
                               spread: spread)
          )
        end
      end

      # Score based on ratio of old references and manipulation count
      if years.any? && @publication_year
        stale_ratio = stale_years.size.to_f / [ years.size, 1 ].max
        severity_penalty = manipulations.sum { |m| { "high" => 0.2, "medium" => 0.1, "low" => 0.05 }.fetch(m.severity, 0) }
        integrity = [ 1.0 - stale_ratio * 0.5 - severity_penalty, 0.1 ].max
      else
        integrity = 0.8
      end

      Result.new(
        manipulations: manipulations,
        temporal_integrity_score: integrity.round(2),
        summary: manipulations.any? ?
          I18n.t("heuristic_fallbacks.temporal_manipulation.heuristic_summary", count: manipulations.size) :
          I18n.t("heuristic_fallbacks.temporal_manipulation.no_issues")
      )
    end

    def empty_result
      Result.new(manipulations: [], temporal_integrity_score: 1.0, summary: I18n.t("heuristic_fallbacks.temporal_manipulation.no_analysis"))
    end

    def interaction_type_name
      :temporal_manipulation
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE
        .gsub("%{locale_name}", locale_name)
    end
  end
end
