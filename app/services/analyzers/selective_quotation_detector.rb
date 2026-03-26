module Analyzers
  # Detects selective or misleading quotation — quotes taken out of context to
  # reverse or distort meaning.
  #
  # An article may quote a real person saying real words, yet still mislead by
  # truncating the quote, stripping qualifiers, or splicing separate statements
  # into one. This is one of the most effective manipulation techniques because
  # the reader sees "real quotes" and trusts them at face value.
  #
  # Phase 1: Extract quoted passages from the article body using quotation mark
  #          patterns and attribution phrases.
  # Phase 2 (LLM): For each quotation, compare how the quote is presented in
  #          the article against the broader context available in linked source
  #          articles. Verdict per quote: faithful, truncated, reversed,
  #          fabricated, or unverifiable.
  class SelectiveQuotationDetector
    Quotation = Struct.new(
      :quoted_text,
      :attributed_to,
      :source_url,
      :full_context,
      :verdict,
      :severity,
      :explanation,
      keyword_init: true
    )

    Result = Struct.new(
      :quotations,
      :quotation_integrity_score,
      :summary,
      keyword_init: true
    )

    MAX_QUOTATIONS = 10

    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    # Regex patterns for quoted text (double curly, straight, guillemets, single curly)
    QUOTE_PATTERNS = [
      /\u201C([^\u201D]{10,500})\u201D/,   # "" (curly double)
      /"([^"]{10,500})"/,                    # "" (straight double)
      /\u00AB([^\u00BB]{10,500})\u00BB/,     # «» (guillemets)
      /\u2018([^\u2019]{10,500})\u2019/      # '' (curly single)
    ].freeze

    # Attribution phrases in English and Portuguese
    ATTRIBUTION_PATTERN = /
      (?:said|stated|declared|claimed|argued|wrote|explained|noted|added|
         told|insisted|confirmed|denied|warned|announced|recalled|
         according\s+to|
         disse|afirmou|declarou|alegou|argumentou|escreveu|explicou|
         observou|acrescentou|informou|insistiu|confirmou|negou|
         alertou|anunciou|lembrou|segundo|conforme|de\s+acordo\s+com)
    /xi.freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a quotation integrity analyst for a fact-checking system. Your job is to
      determine whether quoted passages in a news article faithfully represent the
      original speaker's meaning, or whether they have been selectively edited to
      distort the message.

      Common selective quotation patterns:

      1. TRUNCATION: Cutting a quote short to remove qualifiers ("We might consider X"
         becomes "We [will] consider X"). The omitted portion changes the certainty,
         scope, or meaning.

      2. REVERSAL: Quoting someone out of context so the quote appears to support the
         opposite of what the speaker intended. E.g., quoting "I would never support X"
         as evidence they discussed X, omitting the negation.

      3. SPLICING: Combining parts of different statements into one quote, creating a
         meaning the speaker never expressed as a single thought.

      4. FABRICATION: Attributing a quote to someone who never said it, or significantly
         altering the wording beyond what the source material shows.

      5. DECONTEXTUALIZATION: The quote is verbatim accurate but stripped of essential
         surrounding context (e.g., a hypothetical scenario, a devil's advocate argument,
         or a conditional statement presented as unconditional).

      You will receive:
      - The article's text with extracted quotations
      - The body text of linked source articles (when available) for context comparison

      For each quotation, determine:
      - verdict: one of "faithful", "truncated", "reversed", "fabricated", "unverifiable"
        Use "unverifiable" when no source material is available to compare against.
      - severity: "low", "medium", or "high"
        - low: minor truncation that doesn't change meaning
        - medium: meaning is noticeably shifted but core message is preserved
        - high: meaning is reversed, fabricated, or fundamentally distorted
      - explanation: 1-2 sentences explaining your finding
      - full_context: the broader original passage if found in source material, or null
      - source_url: URL of the source where context was found, or null

      Rate overall quotation_integrity_score (0.0-1.0) where:
      - 1.0 = all quotations are faithful or article has no quotations
      - 0.7+ = minor issues (low severity truncations)
      - 0.4-0.7 = significant issues (medium severity, multiple truncations)
      - <0.4 = severe issues (reversals, fabrications, systematic distortion)

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

      # Phase 1: Extract quotations from article body
      extracted = extract_quotations(article.body_text)
      return no_quotations_result if extracted.empty?

      # Gather linked source texts for context comparison
      source_contexts = gather_source_contexts(article)

      # Phase 2: LLM analysis
      llm_result = analyze_quotations(article, extracted, source_contexts)
      return heuristic_fallback(extracted, source_contexts) unless llm_result

      build_result_from_llm(llm_result, extracted)
    end

    private

    # ── Phase 1: Quotation extraction ──

    def extract_quotations(body_text)
      quotations = []
      seen_texts = Set.new

      QUOTE_PATTERNS.each do |pattern|
        body_text.scan(pattern).each do |match|
          text = match.is_a?(Array) ? match.first : match
          text = text.strip
          normalized = text.downcase.gsub(/\s+/, " ")
          next if seen_texts.include?(normalized)

          seen_texts << normalized

          # Look for attribution near the quote
          attributed_to = find_attribution(body_text, text)

          quotations << {
            quoted_text: text,
            attributed_to: attributed_to
          }
        end
      end

      quotations.first(MAX_QUOTATIONS)
    end

    def find_attribution(body_text, quoted_text)
      # Search in a window around the quote for attribution phrases
      escaped = Regexp.escape(quoted_text.first(50))
      window_pattern = /(.{0,150})#{escaped}(.{0,150})/m
      match = body_text.match(window_pattern)
      return nil unless match

      surrounding = "#{match[1]} #{match[2]}"

      # Look for "Name said/disse" or "according to Name/segundo Name" patterns
      name_before = surrounding.match(/([A-Z\u00C0-\u00FF][a-z\u00E0-\u00FF]+(?:\s+[A-Z\u00C0-\u00FF][a-z\u00E0-\u00FF]+){0,3})\s+#{ATTRIBUTION_PATTERN}/i)
      name_after = surrounding.match(/#{ATTRIBUTION_PATTERN}\s+([A-Z\u00C0-\u00FF][a-z\u00E0-\u00FF]+(?:\s+[A-Z\u00C0-\u00FF][a-z\u00E0-\u00FF]+){0,3})/i)

      (name_before && name_before[1]) || (name_after && name_after[1]) || nil
    end

    # ── Source context gathering ──

    def gather_source_contexts(article)
      links = article.sourced_links.where(follow_status: "crawled").includes(:target_article)

      links.filter_map do |link|
        target = link.target_article
        next unless target&.body_text.present?

        {
          url: link.href,
          title: target.title,
          body_excerpt: target.body_text.truncate(4000)
        }
      end
    end

    # ── Phase 2: LLM analysis ──

    def analyze_quotations(article, extracted, source_contexts)
      return nil unless llm_available?

      prompt = build_prompt(article, extracted, source_contexts)
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
      Rails.logger.warn("Selective quotation analysis LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article, extracted, source_contexts)
      quotations_data = extracted.map do |q|
        { quoted_text: q[:quoted_text], attributed_to: q[:attributed_to] }
      end

      source_data = source_contexts.map do |ctx|
        { url: ctx[:url], title: ctx[:title], body_excerpt: ctx[:body_excerpt] }
      end

      {
        article_title: article.title,
        article_text: article.body_text.to_s.truncate(5000),
        article_host: article.host,
        extracted_quotations: quotations_data,
        linked_source_texts: source_data
      }.to_json
    end

    def response_schema
      {
        name: "selective_quotation_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            quotations: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  quoted_text: { type: "string" },
                  attributed_to: { type: [ "string", "null" ] },
                  source_url: { type: [ "string", "null" ] },
                  full_context: { type: [ "string", "null" ] },
                  verdict: {
                    type: "string",
                    enum: %w[faithful truncated reversed fabricated unverifiable]
                  },
                  severity: {
                    type: "string",
                    enum: %w[low medium high]
                  },
                  explanation: { type: "string" }
                },
                required: %w[quoted_text verdict severity explanation]
              }
            },
            quotation_integrity_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[quotations quotation_integrity_score summary]
        }
      }
    end

    # ── Result building ──

    def build_result_from_llm(llm_result, _extracted)
      quotations = Array(llm_result[:quotations]).map do |q|
        Quotation.new(
          quoted_text: q[:quoted_text].to_s,
          attributed_to: q[:attributed_to],
          source_url: q[:source_url],
          full_context: q[:full_context],
          verdict: q[:verdict].to_s,
          severity: q[:severity].to_s,
          explanation: q[:explanation].to_s
        )
      end

      score = llm_result[:quotation_integrity_score].to_f.clamp(0, 1).round(2)

      Result.new(
        quotations: quotations,
        quotation_integrity_score: score,
        summary: llm_result[:summary].to_s
      )
    end

    # ── Heuristic fallback ──

    def heuristic_fallback(extracted, source_contexts)
      has_sources = source_contexts.any?

      quotations = extracted.map do |q|
        Quotation.new(
          quoted_text: q[:quoted_text],
          attributed_to: q[:attributed_to],
          source_url: nil,
          full_context: nil,
          verdict: has_sources ? "unverifiable" : "unverifiable",
          severity: "low",
          explanation: I18n.t("heuristic_fallbacks.selective_quotation.unverifiable_explanation")
        )
      end

      # No linked articles to compare against: all unverifiable, score 0.5
      # No quotations at all would have returned early via no_quotations_result
      score = has_sources ? 0.5 : 0.5

      Result.new(
        quotations: quotations,
        quotation_integrity_score: score,
        summary: I18n.t("heuristic_fallbacks.selective_quotation.heuristic_summary", count: extracted.size)
      )
    end

    def empty_result
      Result.new(
        quotations: [],
        quotation_integrity_score: 1.0,
        summary: I18n.t("heuristic_fallbacks.selective_quotation.no_analysis")
      )
    end

    def no_quotations_result
      Result.new(
        quotations: [],
        quotation_integrity_score: 1.0,
        summary: I18n.t("heuristic_fallbacks.selective_quotation.no_quotations")
      )
    end

    # ── LLM helpers ──

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :selective_quotation,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create selective quotation interaction: #{e.message}")
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
      Rails.logger.warn("Failed to update selective quotation interaction: #{e.message}")
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
