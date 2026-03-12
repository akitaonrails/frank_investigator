require "test_helper"

class Llm::RubyLlmClientConsensusTest < ActiveSupport::TestCase
  test "aggregate_results picks verdict by weighted confidence not head count" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.95, reason_summary: "Strong support"),
      Llm::RubyLlmClient::Result.new(verdict: "disputed", confidence_score: 0.3, reason_summary: "Weak dispute"),
      Llm::RubyLlmClient::Result.new(verdict: "disputed", confidence_score: 0.3, reason_summary: "Weak dispute 2")
    ]

    aggregated = client.send(:aggregate_results, results)

    # Supported has 0.95 weight vs disputed 0.6 total
    assert_equal "supported", aggregated.verdict
    assert_not aggregated.unanimous
  end

  test "aggregate_results marks unanimous when all agree" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.8, reason_summary: "A"),
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.9, reason_summary: "B")
    ]

    aggregated = client.send(:aggregate_results, results)

    assert aggregated.unanimous
    assert_equal "All models agree: supported (80%)", aggregated.disagreement_details
    assert_equal 0, client.send(:compute_disagreement_penalty, results)
  end

  test "adjacent verdict pair gets 0.08 penalty" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.8, reason_summary: "A"),
      Llm::RubyLlmClient::Result.new(verdict: "mixed", confidence_score: 0.7, reason_summary: "B")
    ]

    assert_equal 0.08, client.send(:compute_disagreement_penalty, results)
  end

  test "opposed verdict pair gets 0.15 penalty" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.8, reason_summary: "A"),
      Llm::RubyLlmClient::Result.new(verdict: "disputed", confidence_score: 0.7, reason_summary: "B")
    ]

    assert_equal 0.15, client.send(:compute_disagreement_penalty, results)
  end

  test "three or more different verdicts gets 0.25 penalty" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.8, reason_summary: "A"),
      Llm::RubyLlmClient::Result.new(verdict: "mixed", confidence_score: 0.7, reason_summary: "B"),
      Llm::RubyLlmClient::Result.new(verdict: "disputed", confidence_score: 0.6, reason_summary: "C")
    ]

    assert_equal 0.25, client.send(:compute_disagreement_penalty, results)
  end

  test "quarantined models are excluded" do
    ENV["QUARANTINED_MODELS"] = "bad-model,another-bad"
    client = Llm::RubyLlmClient.new(models: [ "good-model", "bad-model", "another-bad" ])

    assert_equal [ "good-model" ], client.instance_variable_get(:@models)
  ensure
    ENV.delete("QUARANTINED_MODELS")
  end

  test "available? returns false without API key" do
    original = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = nil
    client = Llm::RubyLlmClient.new(models: [ "some-model" ])

    assert_not client.available?
  ensure
    ENV["OPENROUTER_API_KEY"] = original
  end

  test "available? returns false with no models" do
    client = Llm::RubyLlmClient.new(models: [])
    assert_not client.available?
  end

  test "call returns nil when not available" do
    original = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = nil
    client = Llm::RubyLlmClient.new(models: [ "model" ])
    claim = Claim.create!(canonical_text: "Test", canonical_fingerprint: "llm_avail_#{SecureRandom.hex(4)}")

    result = client.call(claim:, evidence_packet: [])
    assert_nil result
  ensure
    ENV["OPENROUTER_API_KEY"] = original
  end

  test "parse_response extracts and clamps values" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    result = client.send(:parse_response, {
      "verdict" => "supported",
      "confidence_score" => 1.5,
      "reason_summary" => "Reason text"
    })

    assert_equal "supported", result.verdict
    assert_equal 0.97, result.confidence_score
    assert_equal "Reason text", result.reason_summary
  end

  test "build_prompt includes claim data and evidence" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])
    claim = Claim.create!(canonical_text: "Test claim", canonical_fingerprint: "bp_#{SecureRandom.hex(4)}", claim_kind: :statement)

    prompt = client.send(:build_prompt, claim:, evidence_packet: [ { url: "https://ex.com", stance: "supports" } ])
    parsed = JSON.parse(prompt)

    assert_equal "Test claim", parsed["claim"]
    assert_equal "statement", parsed["claim_kind"]
    assert_equal 1, parsed["evidence_count"]
  end

  test "system_prompt interpolates locale" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    I18n.with_locale(:en) do
      assert_includes client.send(:system_prompt), "English"
    end

    I18n.with_locale(:"pt-BR") do
      assert_includes client.send(:system_prompt), "Brazilian Portuguese"
    end
  end

  test "disagreement details string lists each model verdict" do
    client = Llm::RubyLlmClient.new(models: [ "a" ])

    results = [
      Llm::RubyLlmClient::Result.new(verdict: "supported", confidence_score: 0.8, reason_summary: "A"),
      Llm::RubyLlmClient::Result.new(verdict: "disputed", confidence_score: 0.6, reason_summary: "B")
    ]

    aggregated = client.send(:aggregate_results, results)
    assert_includes aggregated.disagreement_details, "Models disagree"
    assert_includes aggregated.disagreement_details, "supported (80%)"
    assert_includes aggregated.disagreement_details, "disputed (60%)"
  end
end
