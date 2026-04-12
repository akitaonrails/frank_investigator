require "test_helper"
require "ostruct"

class Articles::SyncClaimsTest < ActiveSupport::TestCase
  test "reconciles existing claim to not_checkable when a stricter classifier reruns it" do
    article = Article.create!(
      url: "https://example.com/opinion",
      normalized_url: "https://example.com/opinion",
      host: "example.com",
      title: "X foi um bom ministro",
      body_text: "Texto",
      fetch_status: :fetched
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :processing
    )

    claim = Claim.create!(
      canonical_text: "X foi um bom ministro.",
      canonical_fingerprint: Analyzers::ClaimFingerprint.call("X foi um bom ministro.", canonical_form: "X foi um bom ministro."),
      canonical_form: "X foi um bom ministro.",
      semantic_key: "x_bom_ministro",
      checkability_status: :checkable
    )

    extractor_result = Analyzers::ClaimExtractor::Result.new(
      canonical_text: "X foi um bom ministro.",
      surface_text: "X foi um bom ministro.",
      role: :headline,
      checkability_status: :not_checkable,
      importance_score: 1.0,
      canonical_form: "X foi um bom ministro.",
      semantic_key: "x_bom_ministro"
    )

    decomposed = OpenStruct.new(
      canonical_text: "X foi um bom ministro.",
      checkability_status: :not_checkable,
      claim_kind: :statement,
      entities: {},
      time_scope: nil,
      claim_timestamp_start: nil,
      claim_timestamp_end: nil
    )

    with_singleton_override(Analyzers::ClaimExtractor, :call, ->(*, **) { [ extractor_result ] }) do
      with_singleton_override(Analyzers::ClaimDecomposer, :call, ->(*, **) { [ decomposed ] }) do
        Articles::SyncClaims.call(investigation:, article:)
      end
    end

    assert_equal "not_checkable", claim.reload.checkability_status
  end

  private

  def with_singleton_override(target, method_name, replacement)
    singleton = target.singleton_class
    original = target.method(method_name)
    singleton.define_method(method_name, &replacement)
    yield
  ensure
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
