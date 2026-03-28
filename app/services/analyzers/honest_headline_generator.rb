module Analyzers
  # Generates what the article's headline SHOULD have been, based on the
  # full analysis context. Runs after all other analyzers complete.
  #
  # Uses the article's claims, contextual gaps, coordination findings,
  # and the original headline to produce a more accurate, balanced title
  # that doesn't omit critical context or use euphemistic framing.
  class HonestHeadlineGenerator
    include LlmHelpers

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a headline editor for a fact-checking system. You will receive:
      1. The original article headline
      2. The article's key claims and their verdicts
      3. Contextual gaps found (what the article omits)
      4. Coordination findings (euphemistic framing, causal chain erasure)
      5. The investigation summary
      6. EVENT CONTEXT from related investigations — this is the MOST IMPORTANT input.
         It contains a composite timeline built from multiple articles about the same
         event and critical omissions found by comparing coverage across outlets.

      Your job: write what the headline SHOULD have been — a more honest,
      complete headline that:
      - PRIORITIZE the event context. If the composite timeline reveals facts the
        original article omits (e.g., a "cut" was actually a reversal of a prior
        increase, or a "right" was actually a last resort after institutional failure),
        the honest headline MUST include that context.
      - LEAD WITH THE CAUSE, NOT THE PROCEDURE. If the event has a causal chain
        (e.g., crime → injury → consequence), the headline must start with the
        originating cause, not the final procedural step. A headline about a court
        ruling should mention what caused the case, not just who won.
      - Avoids euphemistic language that downplays severity
      - Doesn't sensationalize either — be factual, not dramatic
      - Stays within reasonable headline length (max 150 characters)

      If the original headline is already accurate and balanced, return it unchanged.

      IMPORTANT: Write the headline in %{locale_name}.

      CRITICAL — NO HALLUCINATION: Base the headline ONLY on facts present in the
      provided analysis data. Do not add facts from your own knowledge.

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
      return nil unless article&.title.present? && llm_available?

      prompt = build_prompt(article)
      fingerprint = Digest::SHA256.hexdigest("honest_headline:#{prompt}")
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return cached.response_json&.dig("honest_headline")
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

      payload["honest_headline"].to_s.presence
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Honest headline generation failed: #{e.message}")
      nil
    end

    private

    def build_prompt(article)
      claims = @investigation.claim_assessments.includes(:claim).map do |ca|
        { claim: ca.claim.canonical_text, verdict: ca.verdict }
      end

      gaps = Array(@investigation.contextual_gaps&.dig("gaps")).first(3).map { |g| g["question"] }
      coordination = @investigation.coordinated_narrative || {}
      summary = @investigation.llm_summary || {}
      event = @investigation.event_context || {}

      {
        original_headline: article.title,
        article_host: article.host,
        claims: claims,
        headline_bait_score: @investigation.headline_bait_score.to_f,
        contextual_gaps: gaps,
        convergent_framing: Array(coordination["convergent_framing"]).first(3),
        convergent_omissions: Array(coordination["convergent_omissions"]).first(3),
        summary_quality: summary["overall_quality"],
        summary_weaknesses: Array(summary["weaknesses"]).first(3),
        event_context: {
          composite_timeline: event["composite_timeline"].to_s.truncate(500),
          critical_omissions: Array(event["critical_omissions"]).first(3)
        }.presence
      }.compact.to_json
    end

    def response_schema
      {
        name: "honest_headline",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            honest_headline: { type: "string", description: "The more honest, balanced headline (max 120 chars)" },
            reason: { type: "string", description: "Why the headline was changed (or 'unchanged' if already accurate)" }
          },
          required: %w[honest_headline reason]
        }
      }
    end

    def interaction_type_name
      :investigation_summary # reuse existing type
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE.gsub("%{locale_name}", locale_name)
    end
  end
end
