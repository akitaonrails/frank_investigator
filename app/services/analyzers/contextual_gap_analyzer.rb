module Analyzers
  # Detects what an article chooses NOT to say — the omissions that let factually
  # correct claims assemble into a misleading narrative.
  #
  # An article can pass every individual fact-check while still being manipulative
  # through selective evidence: citing real studies that don't apply to the local
  # context, omitting well-known counter-evidence, or presenting theory as if it
  # were proven practice in the situation being discussed.
  #
  # Phase 1: LLM identifies critical unaddressed questions given the article's
  #          topic, claims, and conclusion.
  # Phase 2: Web search finds evidence that addresses those gaps, revealing
  #          what the article left out.
  class ContextualGapAnalyzer
    Gap = Struct.new(:question, :relevance, :search_results, keyword_init: true)
    SearchEvidence = Struct.new(:url, :title, :snippet, keyword_init: true)

    Result = Struct.new(
      :gaps,
      :completeness_score,
      :summary,
      keyword_init: true
    )

    MAX_GAPS = 5
    MAX_SEARCH_PER_GAP = 3

    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a critical analysis expert for a fact-checking system. Your job is to identify
      what an article DOESN'T address — the questions a well-informed reader would ask that
      the article leaves unanswered.

      Articles can be factually correct in every individual claim while still being misleading
      through omission. Common patterns:

      1. SCOPE MISMATCH: Citing studies from one context (e.g., US data) to justify conclusions
         about a different context (e.g., Brazil) without acknowledging the differences.

      2. MISSING COUNTER-EVIDENCE: Omitting well-known facts, events, or data that would
         complicate or contradict the article's conclusion.

      3. THEORETICAL VS PRACTICAL: Presenting economic/scientific theory as if it directly
         applies to the specific real-world situation, ignoring implementation realities
         (corruption, institutional failures, political context).

      4. DISTRIBUTIONAL BLINDNESS: Discussing aggregate effects (GDP, innovation) while
         ignoring who bears the costs (inflation on the poor, regional disparities).

      5. CAUSAL CHAIN GAPS: Assuming A→C when the real chain is A→B→C, and B is broken
         in the specific context (e.g., "high prices → innovation" assumes functional
         markets and institutions that may not exist).

      6. HISTORICAL AMNESIA: Making claims about what "will happen" while ignoring that
         the same conditions existed before without the predicted outcome.

      You will receive the article's title, excerpt, assessed claims with verdicts, and
      any rhetorical analysis already performed.

      Generate up to %{max_gaps} critical questions that the article fails to address.
      Each question should:
      - Be specific enough to search for evidence
      - Challenge an assumption the article relies on
      - Be answerable with publicly available data/reporting

      For each question, provide:
      - question: The unaddressed question (phrased as a question)
      - relevance: Why this gap matters for evaluating the article's conclusion (1-2 sentences)
      - search_query: A concise web search query (under 12 words) to find evidence addressing this gap

      Rate overall completeness_score (0.0-1.0) where:
      - 1.0 = article addresses all relevant context (rare for opinion pieces)
      - 0.7+ = minor gaps that don't undermine the conclusion
      - 0.4-0.7 = significant gaps that weaken the argument
      - <0.4 = critical context missing that could reverse the conclusion

      IMPORTANT: Write questions, relevance, and summary in %{locale_name}.
      The search_query should be in the language most likely to find relevant results
      (usually the same language as the article).


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
      return empty_result unless assessed_claims.any?

      # Phase 1: Identify gaps via LLM
      gap_questions = identify_gaps(article)
      return heuristic_fallback(article) unless gap_questions

      # Phase 2: Search for counter-evidence
      gaps = search_for_evidence(gap_questions)

      completeness = gap_questions[:completeness_score].to_f.clamp(0, 1).round(2)
      Result.new(
        gaps: gaps,
        completeness_score: completeness,
        summary: gap_questions[:summary].to_s
      )
    end

    private

    def assessed_claims
      @assessed_claims ||= @investigation.claim_assessments
        .includes(:claim)
        .where.not(verdict: "pending")
        .order(confidence_score: :desc)
    end

    # ── Phase 1: LLM gap identification ──

    def identify_gaps(article)
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
      Rails.logger.warn("Contextual gap analysis LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      claims_context = assessed_claims.map do |assessment|
        {
          claim: assessment.claim.canonical_text,
          verdict: assessment.verdict,
          confidence: assessment.confidence_score.to_f,
          reason: assessment.reason_summary
        }
      end

      rhetorical = @investigation.rhetorical_analysis || {}

      {
        article_title: article.title,
        article_excerpt: article.body_text.to_s.truncate(3000),
        article_host: article.host,
        article_source_kind: article.source_kind,
        assessed_claims: claims_context,
        headline_bait_score: @investigation.headline_bait_score.to_f,
        rhetorical_summary: rhetorical["summary"],
        narrative_bias_score: rhetorical["narrative_bias_score"].to_f,
        fallacy_count: Array(rhetorical["fallacies"]).size,
        upstream_findings: upstream_findings
      }.compact.to_json
    end

    def upstream_findings
      findings = {}
      if (sm = @investigation.source_misrepresentation).present?
        distorted = Array(sm["misrepresentations"]).select { |m| m["verdict"].in?(%w[distorted fabricated]) }
        findings[:distorted_sources] = distorted.map { |m| m["explanation"] } if distorted.any?
      end
      if (sd = @investigation.statistical_deception).present?
        deceptions = Array(sd["deceptions"]).select { |d| d["type"].in?(%w[missing_base denominator_games cherry_picked_baseline]) }
        findings[:statistical_gaps] = deceptions.map { |d| d["explanation"] } if deceptions.any?
      end
      if (sq = @investigation.selective_quotation).present?
        truncated = Array(sq["quotations"]).select { |q| q["verdict"].in?(%w[truncated reversed]) }
        findings[:truncated_quotes] = truncated.map { |q| q["explanation"] } if truncated.any?
      end
      findings.presence
    end

    def response_schema
      {
        name: "contextual_gap_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            gaps: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  question: { type: "string" },
                  relevance: { type: "string" },
                  search_query: { type: "string" }
                },
                required: %w[question relevance search_query]
              }
            },
            completeness_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[gaps completeness_score summary]
        }
      }
    end

    # ── Phase 2: Web search for counter-evidence ──

    def search_for_evidence(gap_data)
      raw_gaps = Array(gap_data[:gaps]).first(MAX_GAPS)

      raw_gaps.map do |gap_hash|
        query = gap_hash[:search_query].to_s
        results = if query.present?
          begin
            Fetchers::WebSearcher.call(query: query, max_results: MAX_SEARCH_PER_GAP)
              .map { |r| SearchEvidence.new(url: r.url, title: r.title, snippet: r.snippet) }
          rescue StandardError => e
            Rails.logger.warn("Contextual gap search failed for '#{query}': #{e.message}")
            []
          end
        else
          []
        end

        Gap.new(
          question: gap_hash[:question].to_s,
          relevance: gap_hash[:relevance].to_s,
          search_results: results
        )
      end
    end

    # ── Heuristic fallback ──

    def heuristic_fallback(article)
      gaps = []

      # Check for scope mismatch: article cites foreign sources for local topic
      if article.host&.match?(/\.com\.br|\.gov\.br/) && foreign_evidence_dominant?
        gaps << Gap.new(
          question: I18n.t("heuristic_fallbacks.contextual_gaps.scope_mismatch_question"),
          relevance: I18n.t("heuristic_fallbacks.contextual_gaps.scope_mismatch_relevance"),
          search_results: []
        )
      end

      # Check for one-sided verdicts: all supported, none disputed
      supported = assessed_claims.count { |a| a.verdict == "supported" }
      disputed = assessed_claims.count { |a| a.verdict == "disputed" }
      if supported > 0 && disputed == 0 && assessed_claims.size >= 2
        gaps << Gap.new(
          question: I18n.t("heuristic_fallbacks.contextual_gaps.one_sided_question"),
          relevance: I18n.t("heuristic_fallbacks.contextual_gaps.one_sided_relevance"),
          search_results: []
        )
      end

      completeness = gaps.empty? ? 0.7 : [ 0.5 - (gaps.size * 0.1), 0.2 ].max

      Result.new(
        gaps: gaps,
        completeness_score: completeness.round(2),
        summary: gaps.any? ? I18n.t("heuristic_fallbacks.contextual_gaps.heuristic_summary", count: gaps.size) : I18n.t("heuristic_fallbacks.contextual_gaps.no_gaps")
      )
    end

    def foreign_evidence_dominant?
      evidence_articles = assessed_claims.flat_map { |a| a.evidence_items.map(&:article) }.compact.uniq
      return false if evidence_articles.empty?

      foreign = evidence_articles.count { |a| !a.host&.match?(/\.br\b/) }
      foreign.to_f / evidence_articles.size > 0.7
    end

    def empty_result
      Result.new(gaps: [], completeness_score: 1.0, summary: I18n.t("heuristic_fallbacks.contextual_gaps.no_analysis"))
    end

    # ── LLM helpers ──

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :contextual_gap_analysis,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create contextual gap interaction: #{e.message}")
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
      Rails.logger.warn("Failed to update contextual gap interaction: #{e.message}")
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
        .gsub("%{max_gaps}", MAX_GAPS.to_s)
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
