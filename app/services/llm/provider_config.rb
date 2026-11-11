module Llm
  module ProviderConfig
    extend self

    OPENROUTER_DEFAULT_MODELS = "openai/gpt-5-mini,anthropic/claude-sonnet-4-6,google/gemini-2.5-pro".freeze
    OPENAI_DEFAULT_MODELS = "gpt-5.6-terra".freeze
    CHEAPER_INFERENCE_DEFAULT_MODELS = "gpt-5.4-mini".freeze
    CHEAPER_INFERENCE_API_BASE = "https://api.cheaperinference.com/v1".freeze
    KNOWN_PROVIDERS = %w[openrouter openai cheaperinference].freeze

    def provider
      raw = Rails.configuration.x.frank_investigator.llm_provider.to_s.presence || "openrouter"
      unless KNOWN_PROVIDERS.include?(raw)
        Rails.logger.warn("[ProviderConfig] Unrecognized LLM provider #{raw.inspect}, falling back to openrouter")
        return "openrouter"
      end
      raw
    end

    def models
      Array(Rails.configuration.x.frank_investigator.llm_models).reject(&:blank?)
    end

    def available?
      defined?(RubyLLM) && api_key_present? && models.any?
    end

    def api_key_present?
      ENV[api_key_env].present?
    end

    def api_key_env
      case provider
      when "openai"
        "OPENAI_API_KEY"
      when "cheaperinference"
        "CHEAPER_INFERENCE_API_KEY"
      else
        "OPENROUTER_API_KEY"
      end
    end

    def default_models_for(selected_provider)
      case selected_provider.to_s
      when "openai"
        OPENAI_DEFAULT_MODELS
      when "cheaperinference"
        CHEAPER_INFERENCE_DEFAULT_MODELS
      else
        OPENROUTER_DEFAULT_MODELS
      end
    end

    def provider_symbol
      provider.to_sym
    end

    def assume_model_exists?
      provider.present?
    end

    def chat(model:)
      return cheaper_inference_chat(model:) if provider == "cheaperinference"

      RubyLLM.chat(
        model:,
        provider: provider_symbol,
        assume_model_exists: assume_model_exists?
      )
    end

    private

    # Cheaper Inference is OpenAI-compatible. RubyLLM has no native provider
    # for it, so use the OpenAI provider in an isolated context with its own
    # key and API base. The global OpenAI configuration stays untouched.
    def cheaper_inference_chat(model:)
      RubyLLM.context do |config|
        config.openai_api_key = ENV["CHEAPER_INFERENCE_API_KEY"]
        config.openai_api_base = CHEAPER_INFERENCE_API_BASE
      end.chat(model:, provider: :openai, assume_model_exists: true)
    end
  end
end
