require "test_helper"

class Llm::ProviderConfigTest < ActiveSupport::TestCase
  test "uses openai api key when llm provider is openai" do
    original_provider = Rails.configuration.x.frank_investigator.llm_provider
    original_models = Rails.configuration.x.frank_investigator.llm_models
    original_openai = ENV["OPENAI_API_KEY"]
    original_openrouter = ENV["OPENROUTER_API_KEY"]

    Rails.configuration.x.frank_investigator.llm_provider = "openai"
    Rails.configuration.x.frank_investigator.llm_models = [ "gpt-5-mini" ]
    ENV["OPENAI_API_KEY"] = "test-openai-key"
    ENV.delete("OPENROUTER_API_KEY")

    assert_equal "OPENAI_API_KEY", Llm::ProviderConfig.api_key_env
    assert_predicate Llm::ProviderConfig, :available?
    assert_equal :openai, Llm::ProviderConfig.provider_symbol
  ensure
    Rails.configuration.x.frank_investigator.llm_provider = original_provider
    Rails.configuration.x.frank_investigator.llm_models = original_models
    ENV["OPENAI_API_KEY"] = original_openai
    ENV["OPENROUTER_API_KEY"] = original_openrouter
  end

  test "uses cheaper inference key and api base when llm provider is cheaperinference" do
    original_provider = Rails.configuration.x.frank_investigator.llm_provider
    original_models = Rails.configuration.x.frank_investigator.llm_models
    original_cheaper_inference = ENV["CHEAPER_INFERENCE_API_KEY"]
    original_openrouter = ENV["OPENROUTER_API_KEY"]

    Rails.configuration.x.frank_investigator.llm_provider = "cheaperinference"
    Rails.configuration.x.frank_investigator.llm_models = [ "gpt-5.4-mini" ]
    ENV["CHEAPER_INFERENCE_API_KEY"] = "test-cheaper-inference-key"
    ENV.delete("OPENROUTER_API_KEY")

    assert_equal "CHEAPER_INFERENCE_API_KEY", Llm::ProviderConfig.api_key_env
    assert_equal "gpt-5.4-mini", Llm::ProviderConfig.default_models_for("cheaperinference")
    assert_predicate Llm::ProviderConfig, :available?

    chat = Llm::ProviderConfig.chat(model: "gpt-5.4-mini")
    assert_equal "gpt-5.4-mini", chat.model.id
    assert_equal "https://api.cheaperinference.com/v1", chat.provider.api_base
    assert_equal "Bearer test-cheaper-inference-key", chat.provider.headers["Authorization"]
    assert_nil RubyLLM.config.openai_api_base
  ensure
    Rails.configuration.x.frank_investigator.llm_provider = original_provider
    Rails.configuration.x.frank_investigator.llm_models = original_models
    ENV["CHEAPER_INFERENCE_API_KEY"] = original_cheaper_inference
    ENV["OPENROUTER_API_KEY"] = original_openrouter
  end
end
