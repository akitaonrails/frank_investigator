module Analyzers
  # Detects whether an article is part of a coordinated narrative campaign.
  #
  # When multiple outlets publish articles about the same event with:
  # - The same narrative framing (who's blamed, who's defended)
  # - The same omissions (what counter-evidence is missing from all of them)
  # - Tight temporal clustering (all within 24-48h)
  # - Focus on meta-narrative (attacking the messenger) rather than investigating substance
  #
  # ...this suggests coordinated narrative distribution, whether organic (editorial
  # alignment) or orchestrated (campaign).
  #
  # Phase 1: LLM extracts a narrative fingerprint from the investigated article
  # Phase 2: Web search finds other articles covering the same event
  # Phase 3: LLM compares the article's fingerprint against the found coverage
  # Phase 4: Score coordination likelihood
  class CoordinatedNarrativeDetector
    include LlmHelpers

    CoverageItem = Struct.new(:url, :title, :snippet, :body_excerpt, keyword_init: true)

    Result = Struct.new(
      :coordination_score,
      :pattern_summary,
      :narrative_fingerprint,
      :similar_coverage,
      :convergent_omissions,
      :convergent_framing,
      keyword_init: true
    )

    MAX_SEARCH_RESULTS = 8
    MAX_FETCH_ARTICLES = 5

    FINGERPRINT_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a media analysis expert. Extract the narrative fingerprint of this article.

      Analyze:
      1. CORE EVENT: What happened? (one sentence)
      2. FRAMING: Who is blamed? Who is defended/victimized? What emotional anchors are used?
      3. STANCE: What conclusion does the article push the reader toward?
      4. ENTITIES: Key people, organizations, and their roles in the narrative
      5. OMISSIONS: What relevant facts about this event does the article NOT mention?
      6. META VS SUBSTANCE: Does the article investigate the underlying facts, or does it focus
         on the meta-narrative (how other media covered it, who said what about whom)?
      7. CAUSAL CHAIN: What is the full causal chain of events? List it as A → B → C.
         Then note: which links does this article include, and which does it skip?
         An article that starts at C without mentioning A is performing causal chain erasure.
      8. EUPHEMISTIC FRAMING: Does the article use softening language to describe severe
         events? Note any instances where a tragedy is framed as empowerment, a failure
         as a choice, or a systemic problem as an individual story.
      9. SEARCH QUERIES: 3 search queries to find other coverage of the same event from
         different editorial perspectives. Queries should be in the article's language.

      IMPORTANT: Write all text fields in %{locale_name}.

      CRITICAL — NO HALLUCINATION: Only reference URLs, sources, claims, quotes, and data
      that are EXPLICITLY present in the input provided to you. Do not invent, guess, or
      fabricate any URL, source name, statistic, quote, or claim. If you cannot verify
      something from the provided text, mark it as "unverifiable" — never fill in details
      you are unsure about. Every excerpt must be traceable to the provided input.

      Return strict JSON matching the schema.
    PROMPT

    COMPARISON_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a media coordination analyst. You will receive:
      1. The narrative fingerprint of an article under investigation
      2. Excerpts from other articles covering the same event

      CRITICAL DISTINCTION: Multiple outlets covering the same news event is NORMAL journalism,
      not evidence of coordination. A major event SHOULD generate wide coverage. The signals
      of coordination are qualitative, not quantitative:

      CONVERGENT RHETORICAL FALLACIES: Do multiple outlets use the same logical fallacies
      (strawman, bait-and-pivot, ad hominem, appeal to authority) in the same direction?
      Independent journalists may cover the same event but would not all deploy the same
      rhetorical tricks unless working from a shared narrative template.

      CONVERGENT SUBSTANTIVE OMISSIONS: Do multiple outlets all omit the same specific
      counter-evidence that would weaken their shared narrative? This is the strongest signal.
      Not all omissions matter — only omissions that:
      - Protect one side while attacking another
      - Exclude documented evidence (court records, official meetings, messages)
      - Remove context that would reverse the article's conclusion
      Independent journalism would find different angles, not identical blind spots.

      DEFLECTION FROM SUBSTANCE: Do the articles focus on attacking the messenger (how the
      story was told) rather than investigating the underlying facts? If most coverage debates
      whether a presentation was fair rather than whether the connections shown are real, this
      is deflection — a hallmark of narrative campaigns that can't challenge the substance.

      META VS SUBSTANCE RATIO: What percentage of each article investigates actual evidence
      vs. discusses media behavior? Articles primarily about "outlet X said Y" rather than
      "here is what the evidence shows" are meta-focused.

      CAUSAL CHAIN ERASURE: When an event has a clear causal chain (A caused B which led
      to C), do multiple outlets start the narrative at C without mentioning A? This is one
      of the most effective sanitization techniques: by removing the cause, the outcome
      appears inevitable or even positive. Example: "Person receives benefit X" (starting
      at C) vs "Person suffered event A which caused condition B, leading to outcome C
      after institutions failed to address the root cause" (full chain A→B→C). If most
      outlets erase the same links in the causal chain, this is convergent sanitization.

      EUPHEMISTIC CONVERGENCE: Do multiple outlets use the same softening language to
      describe a tragedy? When several outlets frame a devastating outcome in empowering
      or neutral terms ("obtained the right to", "chose to", "her decision") instead of
      describing the underlying horror, this is coordinated euphemism — especially when
      the body text reveals the severity that the framing conceals. An article that calls
      something a "right" when it's actually a last resort after institutional failure is
      performing narrative laundering — making a systemic failure look like individual
      empowerment.

      WHAT IS NOT COORDINATION:
      - Multiple outlets reporting the same facts (that's just news)
      - Similar headlines about a major event (natural news cycle)
      - Shared political alignment without shared fallacies (editorial bias, not coordination)
      - Different conclusions drawn from the same evidence (healthy journalism)
      - One outlet presenting the full causal chain while others sanitize it — the
        complete version is NOT more "biased", it's more honest. Penalize sanitization,
        not completeness.

      Rate coordination_score (0.0-1.0):
      - 0.0-0.2: Normal independent coverage, different angles and conclusions
      - 0.2-0.4: Editorial alignment but different analysis and evidence used
      - 0.4-0.6: Convergent framing with shared fallacies OR shared substantive omissions
      - 0.6-0.8: Convergent fallacies AND convergent omissions AND deflection from substance
      - 0.8-1.0: Near-identical narrative structure, identical omissions, same fallacies,
        primarily meta-focused — strong evidence of shared narrative source

      IMPORTANT: Write all text fields in %{locale_name}.

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

      # Phase 1: Extract narrative fingerprint
      fingerprint = extract_fingerprint(article)
      return empty_result unless fingerprint

      # Phase 2: Search for related coverage
      coverage = find_related_coverage(fingerprint)
      return minimal_result(fingerprint) if coverage.empty?

      # Phase 3: Compare narratives
      comparison = compare_narratives(fingerprint, coverage)
      return minimal_result(fingerprint) unless comparison

      Result.new(
        coordination_score: comparison[:coordination_score].to_f.clamp(0, 1).round(2),
        pattern_summary: comparison[:pattern_summary].to_s,
        narrative_fingerprint: fingerprint,
        similar_coverage: coverage.map { |c| { url: c.url, title: c.title, snippet: c.snippet } },
        convergent_omissions: Array(comparison[:convergent_omissions]),
        convergent_framing: Array(comparison[:convergent_framing])
      )
    end

    private

    # ── Phase 1: Narrative fingerprint ──

    def extract_fingerprint(article)
      return nil unless llm_available?

      prompt = {
        article_title: article.title,
        article_body: article.body_text.to_s.truncate(4000),
        article_host: article.host,
        article_source_kind: article.source_kind,
        assessed_claims: assessed_claims_context,
        contextual_gaps: Array(@investigation.contextual_gaps&.dig("gaps")).map { |g| g["question"] }
      }.to_json

      fingerprint_text = "fingerprint:#{prompt}"
      fp_hash = Digest::SHA256.hexdigest(fingerprint_text)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fp_hash, model_id: model))
        return cached.response_json&.deep_symbolize_keys
      end

      interaction = create_interaction(model, prompt, fp_hash)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        llm_chat(model:)
          .with_instructions(fingerprint_system_prompt)
          .with_schema(fingerprint_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      payload.deep_symbolize_keys
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Narrative fingerprint extraction failed: #{e.message}")
      nil
    end

    def fingerprint_schema
      {
        name: "narrative_fingerprint",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            core_event: { type: "string" },
            blamed_entities: { type: "array", items: { type: "string" } },
            defended_entities: { type: "array", items: { type: "string" } },
            emotional_anchors: { type: "array", items: { type: "string" } },
            stance: { type: "string" },
            key_omissions: { type: "array", items: { type: "string" } },
            causal_chain: { type: "string", description: "Full causal chain as A -> B -> C, noting which links are present/missing" },
            euphemistic_framing: { type: "array", items: { type: "string" }, description: "Instances where severity is softened or tragedies framed as empowerment" },
            meta_vs_substance: { type: "string", enum: %w[mostly_meta mostly_substance balanced] },
            search_queries: { type: "array", items: { type: "string" } }
          },
          required: %w[core_event blamed_entities defended_entities emotional_anchors stance key_omissions causal_chain euphemistic_framing meta_vs_substance search_queries]
        }
      }
    end

    # ── Phase 2: Find related coverage ──

    def find_related_coverage(fingerprint)
      queries = Array(fingerprint[:search_queries]).first(3)
      return [] if queries.empty?

      all_results = []
      seen_urls = [ @investigation.normalized_url ].to_set

      queries.each do |query|
        results = Fetchers::WebSearcher.call(query: query, max_results: MAX_SEARCH_RESULTS)
        results.each do |r|
          next if seen_urls.include?(r.url)
          seen_urls << r.url
          all_results << CoverageItem.new(url: r.url, title: r.title, snippet: r.snippet)
        end
      rescue StandardError => e
        Rails.logger.warn("Coverage search failed for '#{query}': #{e.message}")
      end

      # Fetch body excerpts for the top results
      all_results.first(MAX_FETCH_ARTICLES).each do |item|
        item.body_excerpt = fetch_excerpt(item.url)
      end

      all_results.first(MAX_FETCH_ARTICLES)
    end

    def fetch_excerpt(url)
      fetcher_class = Rails.application.config.x.frank_investigator.fetcher_class&.constantize || Fetchers::ChromiumFetcher
      result = fetcher_class.call(url: url)
      extracted = Parsing::MainContentExtractor.call(html: result.html, url: url)
      extracted.body_text.to_s.truncate(1500)
    rescue StandardError => e
      Rails.logger.warn("Coverage fetch failed for #{url}: #{e.message}")
      nil
    end

    # ── Phase 3: Compare narratives ──

    def compare_narratives(fingerprint, coverage)
      return nil unless llm_available?

      coverage_data = coverage.map do |item|
        {
          url: item.url,
          title: item.title,
          snippet: item.snippet,
          body_excerpt: item.body_excerpt.to_s.truncate(800)
        }
      end

      prompt = {
        investigated_article: {
          title: @investigation.root_article&.title,
          host: @investigation.root_article&.host,
          fingerprint: fingerprint
        },
        related_coverage: coverage_data
      }.to_json

      comparison_text = "comparison:#{prompt}"
      fp_hash = Digest::SHA256.hexdigest(comparison_text)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fp_hash, model_id: model))
        return cached.response_json&.deep_symbolize_keys
      end

      interaction = create_interaction(model, prompt, fp_hash)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        llm_chat(model:)
          .with_instructions(comparison_system_prompt)
          .with_schema(comparison_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      payload.deep_symbolize_keys
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Narrative comparison failed: #{e.message}")
      nil
    end

    def comparison_schema
      {
        name: "narrative_comparison",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            coordination_score: { type: "number" },
            pattern_summary: { type: "string" },
            convergent_framing: {
              type: "array",
              items: { type: "string" },
              description: "Shared framing patterns across outlets"
            },
            convergent_omissions: {
              type: "array",
              items: { type: "string" },
              description: "Counter-evidence that ALL outlets omit"
            }
          },
          required: %w[coordination_score pattern_summary convergent_framing convergent_omissions]
        }
      }
    end

    # ── Helpers ──

    def assessed_claims_context
      @investigation.claim_assessments
        .includes(:claim)
        .where.not(verdict: "pending")
        .map { |a| { claim: a.claim.canonical_text, verdict: a.verdict } }
    end

    def empty_result
      Result.new(
        coordination_score: 0.0,
        pattern_summary: I18n.t("heuristic_fallbacks.coordinated_narrative.no_analysis"),
        narrative_fingerprint: {},
        similar_coverage: [],
        convergent_omissions: [],
        convergent_framing: []
      )
    end

    def minimal_result(fingerprint)
      Result.new(
        coordination_score: 0.0,
        pattern_summary: I18n.t("heuristic_fallbacks.coordinated_narrative.insufficient_coverage"),
        narrative_fingerprint: fingerprint,
        similar_coverage: [],
        convergent_omissions: [],
        convergent_framing: []
      )
    end

    def interaction_type_name
      :coordinated_narrative
    end

    def fingerprint_system_prompt
      FINGERPRINT_SYSTEM_PROMPT.gsub("%{locale_name}", locale_name)
    end

    def comparison_system_prompt
      COMPARISON_SYSTEM_PROMPT.gsub("%{locale_name}", locale_name)
    end
  end
end
