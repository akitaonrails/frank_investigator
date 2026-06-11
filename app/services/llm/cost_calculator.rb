module Llm
  class CostCalculator
    # OpenRouter pricing per 1M tokens (as of March 2026)
    # Source: https://openrouter.ai/models
    # Format: model_pattern => { input: $/1M_tokens, output: $/1M_tokens }
    PRICING = {
      "openai/gpt-5-mini" => { input: 0.40, output: 1.60 },
      "openai/gpt-4.1-mini" => { input: 0.40, output: 1.60 },
      "openai/gpt-4.1-nano" => { input: 0.10, output: 0.40 },
      "openai/gpt-4o-mini" => { input: 0.15, output: 0.60 },
      "anthropic/claude-sonnet-4-6" => { input: 3.00, output: 15.00 },
      "anthropic/claude-3.7-sonnet" => { input: 3.00, output: 15.00 },
      "anthropic/claude-3.5-sonnet" => { input: 3.00, output: 15.00 },
      "anthropic/claude-3.5-haiku" => { input: 0.80, output: 4.00 },
      "google/gemini-2.5-pro" => { input: 1.25, output: 10.00 },
      "google/gemini-2.5-flash" => { input: 0.15, output: 0.60 },
      "google/gemini-2.0-flash" => { input: 0.10, output: 0.40 },
      "x-ai/grok-4.3" => { input: 1.25, output: 2.50 },
      "x-ai/grok-4.20" => { input: 1.25, output: 2.50 }
    }.freeze

    # Fallback pricing for unknown models (conservative estimate)
    DEFAULT_PRICING = { input: 1.00, output: 5.00 }.freeze

    def self.call(model_id:, prompt_tokens:, completion_tokens:)
      pricing = PRICING[model_id] || DEFAULT_PRICING

      input_cost = (prompt_tokens.to_i / 1_000_000.0) * pricing[:input]
      output_cost = (completion_tokens.to_i / 1_000_000.0) * pricing[:output]

      (input_cost + output_cost).round(6)
    end

    def self.compute_for_interaction!(interaction)
      return unless interaction&.completed?
      return if interaction.prompt_tokens.blank? && interaction.completion_tokens.blank?

      cost = call(
        model_id: interaction.model_id,
        prompt_tokens: interaction.prompt_tokens,
        completion_tokens: interaction.completion_tokens
      )
      interaction.update_column(:cost_usd, cost)
      cost
    end
  end
end
