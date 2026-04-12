module Analyzers
  # Shared LLM interaction helpers for all analyzers.
  # Include in any analyzer that makes LLM calls via the configured LLM provider.
  #
  # Requires the including class to define:
  #   - LOCALE_NAMES (hash) — optional, defaults provided
  #   - interaction_type_name (method) — returns the LlmInteraction enum value
  module LlmHelpers
    LOCALE_NAMES = {
      en: "English",
      "pt-BR": "Brazilian Portuguese"
    }.freeze

    private

    def create_interaction(model, prompt, fingerprint)
      LlmInteraction.create!(
        investigation: @investigation,
        interaction_type: interaction_type_name,
        model_id: model,
        prompt_text: prompt,
        evidence_packet_fingerprint: fingerprint,
        status: :pending
      )
    rescue StandardError => e
      Rails.logger.warn("Failed to create #{interaction_type_name} interaction: #{e.message}")
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
      Rails.logger.warn("Failed to update #{interaction_type_name} interaction: #{e.message}")
    end

    def fail_interaction(interaction, error)
      return unless interaction
      interaction.update!(status: :failed, error_class: error.class.name, error_message: error.message.truncate(500))
    rescue StandardError
      nil
    end

    def llm_available?
      Llm::ProviderConfig.available?
    end

    def primary_model
      Llm::ProviderConfig.models.first || "gpt-5-mini"
    end

    def llm_chat(model: primary_model)
      Llm::ProviderConfig.chat(model:)
    end

    def llm_timeout
      ENV.fetch("LLM_TIMEOUT_SECONDS", 120).to_i
    end

    def unwrap_json(content)
      text = content.to_s.strip
      text = text.sub(/\A```(?:json)?\s*\n?/, "").sub(/\n?\s*```\z/, "") if text.start_with?("```")
      text
    end

    def locale_name
      locales = defined?(self.class::LOCALE_NAMES) ? self.class::LOCALE_NAMES : LOCALE_NAMES
      locales.fetch(I18n.locale, "English")
    end
  end
end
