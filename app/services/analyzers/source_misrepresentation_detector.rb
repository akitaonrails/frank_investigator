module Analyzers
  # Detects when an article misrepresents its cited sources — saying "study shows X"
  # when the study actually says something different, or quoting an expert out of context.
  #
  # This is one of the most effective manipulation techniques: readers rarely click through
  # to verify that a cited source actually supports the article's claim. An article can
  # appear well-sourced while systematically distorting what its sources say.
  #
  # Phase 1: LLM identifies passages where the article references or cites sources and
  #          extracts what the article claims each source says.
  # Phase 2: For each citation, if we have the fetched linked article (via sourced_links
  #          where target_article is fetched), compare the article's claim against what
  #          the source actually says.
  class SourceMisrepresentationDetector
    include LlmHelpers

    Misrepresentation = Struct.new(
      :article_claim,
      :source_url,
      :source_excerpt,
      :verdict,       # accurate / distorted / fabricated / unverifiable
      :severity,      # low / medium / high
      :explanation,
      keyword_init: true
    )

    Result = Struct.new(
      :misrepresentations,
      :misrepresentation_score,
      :summary,
      keyword_init: true
    )

    MAX_CITATIONS = 8
    MAX_SOURCE_CHARS = 3000

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a source verification expert for a fact-checking system. Your job is to detect
      when an article misrepresents what its cited sources actually say.

      Articles frequently distort their sources in these ways:

      1. CHERRY-PICKING: Quoting a study's finding while ignoring its caveats, limitations,
         or contradictory findings in the same paper.

      2. EXAGGERATION: A source says "may be associated with" but the article says "causes"
         or "proves". Upgrading tentative findings to definitive claims.

      3. CONTEXT STRIPPING: Quoting an expert accurately but removing context that changes
         the meaning ("I think X, but only under condition Y" becomes "Expert says X").

      4. FABRICATION: Attributing claims to a source that never made them, or citing a source
         that doesn't exist or doesn't contain the referenced information.

      5. REVERSAL: The source actually says the opposite of what the article claims it says.

      6. SCOPE INFLATION: A source discusses a narrow finding (e.g., one city, one age group)
         but the article presents it as a general conclusion.

      7. OUTDATED CITATION: Citing an old study whose conclusions have been superseded by
         newer research, without acknowledging the update.

      You will receive the article's text and, for each citation where we have the source
      content, the actual text from the cited source.

      For each citation, determine:
      - article_claim: What the article says the source claims (quote or close paraphrase from the article)
      - source_url: The URL of the cited source
      - verdict: One of "accurate", "distorted", "fabricated", or "unverifiable"
      - severity: One of "low", "medium", or "high"
      - explanation: Why this citation is accurate or how it was misrepresented (1-2 sentences)

      If the source content is available, also provide:
      - source_excerpt: The relevant passage from the actual source that shows the truth

      Rate overall misrepresentation_score (0.0-1.0) where:
      - 0.0 = all citations are accurate representations of their sources
      - 0.3 = minor distortions (exaggeration, slight context loss) but core claims hold
      - 0.5 = significant distortions that change the meaning of source claims
      - 0.7+ = systematic misrepresentation or fabrication of sources
      - 1.0 = sources directly contradict the article's claims about them

      IMPORTANT: Write explanations and summary in %{locale_name}.


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

      # Gather linked sources that have been fetched
      @linked_sources = gather_linked_sources(article)

      # Phase 1 & 2: LLM compares article claims against source content
      llm_result = analyze_citations(article)
      return heuristic_fallback(article) unless llm_result

      misrepresentations = build_misrepresentations(llm_result)
      score = llm_result[:misrepresentation_score].to_f.clamp(0, 1).round(2)

      Result.new(
        misrepresentations: misrepresentations,
        misrepresentation_score: score,
        summary: llm_result[:summary].to_s
      )
    end

    private

    def gather_linked_sources(article)
      article.sourced_links
        .where(follow_status: :crawled)
        .includes(:target_article)
        .each_with_object({}) do |link, hash|
          target = link.target_article
          next unless target&.body_text.present?
          hash[link.href] = {
            url: link.href,
            title: target.title,
            body_excerpt: target.body_text.to_s.truncate(MAX_SOURCE_CHARS)
          }
        end
    end

    # ── Phase 1 & 2: LLM citation analysis ──

    def analyze_citations(article)
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
      Rails.logger.warn("Source misrepresentation analysis LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      sources_context = @linked_sources.map do |url, source|
        {
          url: url,
          title: source[:title],
          body_excerpt: source[:body_excerpt]
        }
      end.first(MAX_CITATIONS)

      {
        article_title: article.title,
        article_excerpt: article.body_text.to_s.truncate(3000),
        article_host: article.host,
        fetched_sources: sources_context,
        total_outbound_links: @investigation.root_article.sourced_links.count,
        fetched_source_count: @linked_sources.size
      }.to_json
    end

    def response_schema
      {
        name: "source_misrepresentation_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            misrepresentations: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  article_claim: { type: "string" },
                  source_url: { type: "string" },
                  source_excerpt: { type: "string" },
                  verdict: { type: "string", enum: %w[accurate distorted fabricated unverifiable] },
                  severity: { type: "string", enum: %w[low medium high] },
                  explanation: { type: "string" }
                },
                required: %w[article_claim source_url verdict severity explanation]
              }
            },
            misrepresentation_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[misrepresentations misrepresentation_score summary]
        }
      }
    end

    def build_misrepresentations(llm_result)
      Array(llm_result[:misrepresentations]).first(MAX_CITATIONS).map do |entry|
        Misrepresentation.new(
          article_claim: entry[:article_claim].to_s,
          source_url: entry[:source_url].to_s,
          source_excerpt: entry[:source_excerpt].to_s,
          verdict: entry[:verdict].to_s,
          severity: entry[:severity].to_s,
          explanation: entry[:explanation].to_s
        )
      end
    end

    # ── Heuristic fallback ──

    def heuristic_fallback(article)
      total_links = article.sourced_links.count
      fetched = @linked_sources.size

      misrepresentations = []

      if total_links > 0 && fetched == 0
        # No sources could be verified at all
        score = 0.3
        summary = I18n.t("heuristic_fallbacks.source_misrepresentation.no_sources_fetched",
          total: total_links, default: "None of the %{total} cited sources could be fetched for verification.")
      elsif total_links > 0
        unverifiable_ratio = 1.0 - (fetched.to_f / total_links)
        score = (unverifiable_ratio * 0.4).round(2)
        summary = I18n.t("heuristic_fallbacks.source_misrepresentation.partial_verification",
          fetched: fetched, total: total_links,
          default: "Only %{fetched} of %{total} cited sources could be fetched for verification.")
      else
        # No outbound links at all
        score = 0.0
        summary = I18n.t("heuristic_fallbacks.source_misrepresentation.no_citations",
          default: "Article contains no outbound citations to verify.")
      end

      Result.new(
        misrepresentations: misrepresentations,
        misrepresentation_score: score,
        summary: summary
      )
    end

    def empty_result
      Result.new(
        misrepresentations: [],
        misrepresentation_score: 0.0,
        summary: I18n.t("heuristic_fallbacks.source_misrepresentation.no_analysis",
          default: "Source misrepresentation analysis was not performed.")
      )
    end

    def interaction_type_name
      :source_misrepresentation
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE
        .gsub("%{locale_name}", locale_name)
    end
  end
end
