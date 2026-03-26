module Analyzers
  # Combines 5 independent content analyses into a single LLM call to reduce
  # pipeline latency. Instead of 5 sequential calls (~6 min), one call (~90s).
  #
  # Analyzes: source misrepresentation, temporal manipulation, statistical
  # deception, selective quotation, and authority laundering.
  #
  # Each sub-analysis produces its own result stored in its own JSON column.
  # The individual analyzer services are preserved as fallbacks and for
  # independent re-runs.
  class BatchContentAnalyzer
    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a comprehensive media analysis expert for a fact-checking system. You will perform
      5 analyses on a single article IN ONE PASS. Return all results in a single JSON response.

      The 5 analyses:

      1. SOURCE MISREPRESENTATION: Does the article accurately represent its cited sources?
         Check if the article claims a source says X when it actually says Y. Look for:
         cherry-picking, exaggeration, context stripping, fabrication, reversal, scope inflation.
         For each misrepresentation found, provide: article_claim, source_url (if identifiable),
         verdict (accurate/distorted/fabricated/unverifiable), severity (low/medium/high), explanation.

      2. TEMPORAL MANIPULATION: Is old data presented as current? Look for:
         - stale_data: referencing old data without dating it
         - timeline_mixing: juxtaposing events from different periods to imply causation
         - implicit_recency: present tense for past events
         - selective_timeframe: choosing dates that exaggerate a trend
         For each, provide: type, excerpt, referenced_period, severity, explanation.

      3. STATISTICAL DECEPTION: Are numbers presented misleadingly? Look for:
         - cherry_picked_baseline, relative_absolute_confusion, survivorship_bias,
           scale_manipulation, denominator_games, missing_base
         For each, provide: type, excerpt, severity, explanation, corrective_context.

      4. SELECTIVE QUOTATION: Are quotes taken out of context? For each quotation found,
         provide: quoted_text, attributed_to, verdict (faithful/truncated/reversed/fabricated/
         unverifiable), severity, explanation.

      5. AUTHORITY LAUNDERING: Does the citation chain inflate low-authority sources?
         Look for chains where blogs/social posts get cited by progressively larger outlets
         without new evidence. Provide: chains found, originating vs final authority, severity.

      CALIBRATION: Not every article has problems. Return empty arrays and high integrity
      scores (1.0) when no issues are found. Minor editorial choices are NOT deception.

      CRITICAL — NO HALLUCINATION: Only reference URLs, sources, claims, quotes, and data
      that are EXPLICITLY present in the input provided to you. Do not invent, guess, or
      fabricate any URL, source name, statistic, quote, or claim. If you cannot verify
      something from the provided text, mark it as "unverifiable" — never fill in details
      you are unsure about. Every excerpt must be traceable to the article text provided.

      IMPORTANT: Write all text fields in %{locale_name}.
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
      return empty_results unless article&.body_text.present?

      result = run_batch_analysis(article)
      return run_individual_fallbacks unless result

      result
    end

    private

    def run_batch_analysis(article)
      return nil unless llm_available?

      prompt = build_prompt(article)
      fingerprint = Digest::SHA256.hexdigest("batch:#{prompt}")
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return parse_batch_response(cached.response_json)
      end

      interaction = create_interaction(model, prompt, fingerprint)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)
          .with_instructions(system_prompt)
          .with_schema(batch_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_batch_response(payload)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Batch content analysis failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      claims_context = @investigation.claim_assessments
        .includes(:claim)
        .where.not(verdict: "pending")
        .map { |a| { claim: a.claim.canonical_text, verdict: a.verdict, confidence: a.confidence_score.to_f } }

      # Include linked article excerpts for source comparison
      linked_sources = @investigation.root_article.sourced_links
        .includes(:target_article)
        .select { |l| l.follow_status == "crawled" && l.target_article&.body_text.present? }
        .first(5)
        .map { |l| { url: l.href, host: l.target_article.host, excerpt: l.target_article.body_text.truncate(500) } }

      {
        article_title: article.title,
        article_body: article.body_text.to_s.truncate(4000),
        article_host: article.host,
        article_published_at: article.published_at&.iso8601,
        assessed_claims: claims_context,
        linked_sources: linked_sources
      }.to_json
    end

    def batch_schema
      {
        name: "batch_content_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            source_misrepresentation: {
              type: "object",
              additionalProperties: false,
              properties: {
                misrepresentations: { type: "array", items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    article_claim: { type: "string" }, source_url: { type: "string" },
                    verdict: { type: "string", enum: %w[accurate distorted fabricated unverifiable] },
                    severity: { type: "string", enum: %w[low medium high] },
                    explanation: { type: "string" }
                  }, required: %w[article_claim verdict severity explanation]
                } },
                misrepresentation_score: { type: "number" },
                summary: { type: "string" }
              },
              required: %w[misrepresentations misrepresentation_score summary]
            },
            temporal_manipulation: {
              type: "object",
              additionalProperties: false,
              properties: {
                manipulations: { type: "array", items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    type: { type: "string", enum: %w[stale_data timeline_mixing implicit_recency selective_timeframe] },
                    excerpt: { type: "string" }, referenced_period: { type: "string" },
                    severity: { type: "string", enum: %w[low medium high] },
                    explanation: { type: "string" }
                  }, required: %w[type excerpt severity explanation]
                } },
                temporal_integrity_score: { type: "number" },
                summary: { type: "string" }
              },
              required: %w[manipulations temporal_integrity_score summary]
            },
            statistical_deception: {
              type: "object",
              additionalProperties: false,
              properties: {
                deceptions: { type: "array", items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    type: { type: "string", enum: %w[cherry_picked_baseline relative_absolute_confusion survivorship_bias scale_manipulation denominator_games missing_base] },
                    excerpt: { type: "string" },
                    severity: { type: "string", enum: %w[low medium high] },
                    explanation: { type: "string" },
                    corrective_context: { type: "string" }
                  }, required: %w[type excerpt severity explanation]
                } },
                statistical_integrity_score: { type: "number" },
                summary: { type: "string" }
              },
              required: %w[deceptions statistical_integrity_score summary]
            },
            selective_quotation: {
              type: "object",
              additionalProperties: false,
              properties: {
                quotations: { type: "array", items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    quoted_text: { type: "string" }, attributed_to: { type: "string" },
                    verdict: { type: "string", enum: %w[faithful truncated reversed fabricated unverifiable] },
                    severity: { type: "string", enum: %w[low medium high] },
                    explanation: { type: "string" }
                  }, required: %w[quoted_text verdict severity explanation]
                } },
                quotation_integrity_score: { type: "number" },
                summary: { type: "string" }
              },
              required: %w[quotations quotation_integrity_score summary]
            },
            authority_laundering: {
              type: "object",
              additionalProperties: false,
              properties: {
                chains: { type: "array", items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    steps: { type: "array", items: {
                      type: "object", additionalProperties: false,
                      properties: { url: { type: "string" }, host: { type: "string" }, authority_tier: { type: "string" } },
                      required: %w[host authority_tier]
                    } },
                    originating_authority: { type: "string" }, final_authority: { type: "string" },
                    new_evidence_added: { type: "boolean" },
                    severity: { type: "string", enum: %w[low medium high] },
                    explanation: { type: "string" }
                  }, required: %w[severity explanation]
                } },
                laundering_score: { type: "number" },
                summary: { type: "string" }
              },
              required: %w[chains laundering_score summary]
            }
          },
          required: %w[source_misrepresentation temporal_manipulation statistical_deception selective_quotation authority_laundering]
        }
      }
    end

    def parse_batch_response(payload)
      {
        source_misrepresentation: payload["source_misrepresentation"],
        temporal_manipulation: payload["temporal_manipulation"],
        statistical_deception: payload["statistical_deception"],
        selective_quotation: payload["selective_quotation"],
        authority_laundering: payload["authority_laundering"]
      }
    end

    def run_individual_fallbacks
      {
        source_misrepresentation: run_fallback(Analyzers::SourceMisrepresentationDetector),
        temporal_manipulation: run_fallback(Analyzers::TemporalManipulationDetector),
        statistical_deception: run_fallback(Analyzers::StatisticalDeceptionDetector),
        selective_quotation: run_fallback(Analyzers::SelectiveQuotationDetector),
        authority_laundering: run_fallback(Analyzers::AuthorityLaunderingDetector)
      }
    end

    def run_fallback(klass)
      result = klass.call(investigation: @investigation)
      # Convert struct to hash — each analyzer has different field names
      result.to_h.transform_values { |v| v.is_a?(Array) ? v.map { |i| i.respond_to?(:to_h) ? i.to_h : i } : v }
    rescue StandardError => e
      Rails.logger.warn("Fallback #{klass.name} failed: #{e.message}")
      nil
    end

    def empty_results
      {
        source_misrepresentation: { "misrepresentations" => [], "misrepresentation_score" => 0.0, "summary" => "" },
        temporal_manipulation: { "manipulations" => [], "temporal_integrity_score" => 1.0, "summary" => "" },
        statistical_deception: { "deceptions" => [], "statistical_integrity_score" => 1.0, "summary" => "" },
        selective_quotation: { "quotations" => [], "quotation_integrity_score" => 1.0, "summary" => "" },
        authority_laundering: { "chains" => [], "laundering_score" => 0.0, "summary" => "" }
      }
    end

    # ── LLM helpers ──

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: :batch_content_analysis,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create batch analysis interaction: #{e.message}")
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
      Rails.logger.warn("Failed to update batch analysis interaction: #{e.message}")
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
