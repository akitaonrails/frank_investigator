require "test_helper"
require "open3"

class LlmConfigurationTest < ActiveSupport::TestCase
  test "openai boot default matches provider default and ignores legacy openrouter models" do
    assert_equal [ "gpt-6.1-terra" ], boot_models(
      "FRANK_INVESTIGATOR_LLM_PROVIDER" => "openai",
      "FRANK_INVESTIGATOR_OPENROUTER_MODELS" => "vendor/legacy-model"
    )
    assert_equal "gpt-6.1-terra", Llm::ProviderConfig.default_models_for("openai")
  end

  test "explicit model overrides are preserved and normalized at boot" do
    assert_equal [ "custom-model", "gpt-5-mini", "gpt-5-mini-2025-08-07" ], boot_models(
      "FRANK_INVESTIGATOR_LLM_PROVIDER" => "openai",
      "FRANK_INVESTIGATOR_LLM_MODELS" => " custom-model, ,gpt-5-mini,gpt-5-mini-2025-08-07, "
    )
    assert_equal [], boot_models(
      "FRANK_INVESTIGATOR_LLM_PROVIDER" => "openai",
      "FRANK_INVESTIGATOR_LLM_MODELS" => ""
    )
  end

  test "other providers retain their defaults and legacy openrouter override" do
    assert_equal Llm::ProviderConfig.default_models_for("openrouter").split(","), boot_models
    assert_equal [ "gpt-5.4-mini" ], boot_models("FRANK_INVESTIGATOR_LLM_PROVIDER" => "cheaperinference")
    assert_equal [ "vendor/legacy-model" ], boot_models("FRANK_INVESTIGATOR_OPENROUTER_MODELS" => "vendor/legacy-model")
  end

  private

  def boot_models(overrides = {})
    env = %w[
      FRANK_INVESTIGATOR_LLM_PROVIDER
      FRANK_INVESTIGATOR_LLM_MODELS
      FRANK_INVESTIGATOR_OPENROUTER_MODELS
    ].index_with { nil }.merge(overrides)
    script = "puts JSON.generate(FrankInvestigator::Application.config.x.frank_investigator.llm_models)"
    output, errors, status = Open3.capture3(
      env, RbConfig.ruby, "-r", Rails.root.join("config/application").to_s, "-e", script,
      chdir: Rails.root.to_s
    )
    assert status.success?, errors
    JSON.parse(output)
  end
end
