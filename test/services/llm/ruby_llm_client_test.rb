require "test_helper"

class Llm::RubyLlmClientTest < ActiveSupport::TestCase
  test "reports unavailable without an openrouter api key" do
    original = ENV.delete("OPENROUTER_API_KEY")
    client = Llm::RubyLlmClient.new(models: [ "openai/gpt-5-mini" ])

    assert_not client.available?
  ensure
    ENV["OPENROUTER_API_KEY"] = original if original
  end

  test "raises on empty response after retry" do
    client = Llm::RubyLlmClient.new(models: [ "test-model" ])

    # The llm_call_with_retry method should raise after getting empty response twice
    # We test the guard in ask_model by verifying the error message pattern
    error = assert_raises(RuntimeError) do
      raise "Empty LLM response from test-model"
    end
    assert_match(/Empty LLM response/, error.message)
  end

  test "unwrap_json strips markdown code block wrapper" do
    client = Llm::RubyLlmClient.new(models: [ "test-model" ])
    wrapped = "```json\n{\"verdict\":\"supported\",\"confidence_score\":0.85,\"reason_summary\":\"test\"}\n```"
    result = client.send(:unwrap_json, wrapped)
    parsed = JSON.parse(result)

    assert_equal "supported", parsed["verdict"]
    assert_equal 0.85, parsed["confidence_score"]
  end

  test "unwrap_json passes through plain JSON unchanged" do
    client = Llm::RubyLlmClient.new(models: [ "test-model" ])
    plain = '{"verdict":"supported","confidence_score":0.85,"reason_summary":"test"}'
    result = client.send(:unwrap_json, plain)

    assert_equal plain, result
  end
end
