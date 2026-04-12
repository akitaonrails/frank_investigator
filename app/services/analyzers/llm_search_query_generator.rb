module Analyzers
  class LlmSearchQueryGenerator
    include LlmHelpers

    LLM_TIMEOUT_SECONDS = 30

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You generate concise web search queries to find independent coverage of a factual claim.
      Return 2-3 search queries, each under 10 words.
      Queries should be in the same language as the claim.
      Focus on finding coverage from different outlets.
      Do NOT include the name of the original source outlet.
    PROMPT

    def self.call(claim:, root_article_host: nil, investigation: nil)
      new(claim:, root_article_host:, investigation:).call
    end

    def initialize(claim:, root_article_host:, investigation:)
      @claim = claim
      @root_article_host = root_article_host
      @investigation = investigation
    end

    def call
      return fallback_queries unless llm_available?

      queries = generate_via_llm
      queries.presence || fallback_queries
    rescue StandardError => e
      Rails.logger.warn("[LlmSearchQueryGenerator] LLM call failed: #{e.message}")
      fallback_queries
    end

    private

    def generate_via_llm
      prompt = build_prompt
      model = models.first
      return fallback_queries unless model

      interaction = record_interaction(model:, prompt:) if @investigation

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(LLM_TIMEOUT_SECONDS) do
        llm_chat(model:)
          .with_instructions(SYSTEM_PROMPT)
          .with_schema(response_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?

      content = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      queries = Array(content["queries"]).map(&:to_s).reject(&:blank?).first(3)

      if interaction
        interaction.update!(
          response_text: queries.join("\n"),
          response_json: content,
          status: :completed,
          latency_ms: elapsed_ms,
          prompt_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
          completion_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil
        )
      end

      queries
    rescue StandardError => e
      interaction&.update!(status: :failed, error_class: e.class.name, error_message: e.message.truncate(500))
      raise
    end

    def build_prompt
      parts = []
      parts << "Claim: #{@claim.canonical_text}"
      parts << "Original source host: #{@root_article_host}" if @root_article_host.present?
      parts << "Generate 2-3 concise search queries to find independent coverage of this claim from different outlets."
      parts.join("\n")
    end

    def response_schema
      {
        name: "search_queries",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            queries: {
              type: "array",
              items: { type: "string" },
              description: "2-3 concise search queries under 10 words each"
            }
          },
          required: %w[queries]
        }
      }
    end

    def interaction_type_name
      :search_query_generation
    end

    def record_interaction(model:, prompt:)
      create_interaction(model, prompt, Digest::SHA256.hexdigest(prompt))
    end

    def fallback_queries
      [ @claim.canonical_text.truncate(80) ]
    end

    def llm_available?
      super && models.any?
    end

    def models
      @models ||= Array(Rails.application.config.x.frank_investigator.llm_models)
    end
  end
end
