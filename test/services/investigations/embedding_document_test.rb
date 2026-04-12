require "test_helper"

class Investigations::EmbeddingDocumentTest < ActiveSupport::TestCase
  test "builds a compact embedding document from the article, claims, and gaps" do
    article = Article.create!(
      url: "https://example.com/haddad",
      normalized_url: "https://example.com/haddad",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute Haddad, impostos, politica fiscal e contas publicas.",
      fetch_status: :fetched
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :completed,
      contextual_gaps: {
        "gaps" => [
          { "question" => "Quais foram os resultados fiscais do periodo?" }
        ]
      }
    )
    claim = Claim.create!(
      canonical_text: "Haddad elevou impostos.",
      canonical_fingerprint: "haddad-elevou-impostos-doc",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(
      investigation:,
      claim:,
      verdict: :supported,
      checkability_status: :checkable
    )

    document = Investigations::EmbeddingDocument.call(investigation:)

    assert_includes document, "title: Haddad foi um bom ministro"
    assert_includes document, "host: example.com"
    assert_includes document, "Haddad elevou impostos."
    assert_includes document, "Quais foram os resultados fiscais do periodo?"
    assert_includes document, "body: O texto discute Haddad"
  end
end
