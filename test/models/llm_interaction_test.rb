require "test_helper"

class LlmInteractionTest < ActiveSupport::TestCase
  test "creates interaction with required fields" do
    article = Article.create!(
      url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      host: "example.com"
    )
    investigation = Investigation.create!(
      submitted_url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      root_article: article
    )

    interaction = LlmInteraction.create!(
      investigation:,
      interaction_type: :assessment,
      model_id: "openai/gpt-4o",
      prompt_text: '{"claim":"test","evidence":[]}',
      evidence_packet_fingerprint: "abc123",
      status: :pending
    )

    assert interaction.persisted?
    assert interaction.assessment?
    assert interaction.pending?
  end

  test "finds cached interaction by fingerprint and model" do
    article = Article.create!(
      url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      host: "example.com"
    )
    investigation = Investigation.create!(
      submitted_url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      root_article: article
    )

    LlmInteraction.create!(
      investigation:,
      model_id: "openai/gpt-4o",
      prompt_text: "test",
      evidence_packet_fingerprint: "fp123",
      status: :completed,
      response_json: { "verdict" => "supported", "confidence_score" => 0.85, "reason_summary" => "test" }
    )

    cached = LlmInteraction.find_cached(evidence_packet_fingerprint: "fp123", model_id: "openai/gpt-4o")
    assert_not_nil cached
    assert_equal "supported", cached.response_json["verdict"]

    miss = LlmInteraction.find_cached(evidence_packet_fingerprint: "other", model_id: "openai/gpt-4o")
    assert_nil miss
  end

  test "total_tokens sums prompt and completion" do
    article = Article.create!(
      url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      host: "example.com"
    )
    investigation = Investigation.create!(
      submitted_url: "https://example.com/test",
      normalized_url: "https://example.com/test",
      root_article: article
    )

    interaction = LlmInteraction.create!(
      investigation:,
      model_id: "test-model",
      prompt_text: "test",
      prompt_tokens: 100,
      completion_tokens: 50
    )

    assert_equal 150, interaction.total_tokens
  end
end
