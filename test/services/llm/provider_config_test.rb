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
end
