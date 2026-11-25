require "test_helper"

class Llm::OpenaiMigrationTest < ActiveSupport::TestCase
  setup do
    @original_provider = Rails.configuration.x.frank_investigator.llm_provider
    @original_models = Rails.configuration.x.frank_investigator.llm_models
    @original_key = ENV["OPENAI_API_KEY"]
    @original_config_key = RubyLLM.config.openai_api_key
    @original_quarantine = ENV.delete("QUARANTINED_MODELS")
    Rails.configuration.x.frank_investigator.llm_provider = "openai"
    Rails.configuration.x.frank_investigator.llm_models = [ Llm::ProviderConfig.default_models_for("openai") ]
    ENV["OPENAI_API_KEY"] = "test-openai-key"
    RubyLLM.config.openai_api_key = "test-openai-key"
    @claim = Claim.create!(canonical_text: "The report confirms the claim", canonical_fingerprint: "openai_migration")
    @verdict = { verdict: "supported", confidence_score: 0.85, reason_summary: "The report supports the claim." }
  end

  teardown do
    Rails.configuration.x.frank_investigator.llm_provider = @original_provider
    Rails.configuration.x.frank_investigator.llm_models = @original_models
    ENV["OPENAI_API_KEY"] = @original_key
    RubyLLM.config.openai_api_key = @original_config_key
    ENV["QUARANTINED_MODELS"] = @original_quarantine
  end

  test "default openai model assesses a claim using chat completions structured output" do
    request = stub_completion("claim_assessment", @verdict)

    result = Llm::RubyLlmClient.new.call(claim: @claim, evidence_packet: [])

    assert_not_nil result
    assert_equal "supported", result.verdict
    assert_in_delta 0.85, result.confidence_score
    assert_equal @verdict[:reason_summary], result.reason_summary
    assert_requested request, times: 1
  end

  test "default openai model parses batch assessments" do
    request = stub_completion("batch_claim_assessment", { assessments: [ @verdict ] })

    results = Llm::RubyLlmClient.new.call_batch(items: [ { claim: @claim, evidence_packet: [] } ])

    assert_equal [ @claim.id ], results.keys
    assert_equal "supported", results.fetch(@claim.id).verdict
    assert_equal @verdict[:reason_summary], results.fetch(@claim.id).reason_summary
    assert_requested request, times: 1
  end

  test "empty openai response is retried with the same model and schema" do
    request = stub_completion("claim_assessment", @verdict, empty_first: true)

    result = Llm::RubyLlmClient.new.call(claim: @claim, evidence_packet: [])

    assert_not_nil result
    assert_equal "supported", result.verdict
    assert_requested request, times: 2
  end

  private

  def stub_completion(schema_name, content, empty_first: false)
    request_stub = stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .with(headers: { "Authorization" => "Bearer test-openai-key" }) do |request|
        payload = JSON.parse(request.body)
        assert_equal "gpt-6.1-terra", payload.fetch("model")
        assert_equal "json_schema", payload.dig("response_format", "type")
        assert_equal schema_name, payload.dig("response_format", "json_schema", "name")
        assert_equal true, payload.dig("response_format", "json_schema", "strict")
        assert_equal "user", payload.fetch("messages").last.fetch("role")
        assert_not_empty payload.fetch("messages").first.fetch("content")
        %w[tools tool_choice temperature top_p logprobs top_logprobs reasoning_effort max_tokens max_completion_tokens].each do |key|
          assert_not payload.key?(key), "Unexpected #{key} in OpenAI request"
        end
        true
      end

    responses = [ completion_response(content.to_json) ]
    responses.unshift(completion_response("")) if empty_first
    request_stub.to_return(*responses)
  end

  def completion_response(content)
    {
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: "chatcmpl-migration-test", model: "gpt-6.1-terra",
        choices: [ { message: { role: "assistant", content: content }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
      }.to_json
    }
  end
end
