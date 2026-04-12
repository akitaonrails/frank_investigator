module Llm
  module ProviderConfig
    extend self

    OPENROUTER_DEFAULT_MODELS = "openai/gpt-5-mini,anthropic/claude-sonnet-4-6,google/gemini-2.5-pro".freeze
    OPENAI_DEFAULT_MODELS = "gpt-5-mini".freeze

    def provider
      Rails.configuration.x.frank_investigator.llm_provider.to_s.presence || "openrouter"
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
      else
        "OPENROUTER_API_KEY"
      end
    end

    def default_models_for(selected_provider)
      case selected_provider.to_s
      when "openai"
        OPENAI_DEFAULT_MODELS
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
      RubyLLM.chat(
        model:,
        provider: provider_symbol,
        assume_model_exists: assume_model_exists?
      )
    end
  end
end
