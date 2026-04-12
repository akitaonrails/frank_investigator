require "test_helper"

class Investigations::EmbeddingDocumentTest < ActiveSupport::TestCase
  test "builds a compact embedding document from central identity signals" do
    article = Article.create!(
      url: "https://example.com/haddad",
      normalized_url: "https://example.com/haddad",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute Haddad, impostos, politica fiscal e contas publicas. " \
                 "Daniel Vorcaro aparece apenas como episodio lateral.",
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
    primary_claim = Claim.create!(
      canonical_text: "Haddad elevou impostos.",
      canonical_fingerprint: "haddad-elevou-impostos-doc",
      checkability_status: :checkable
    )
    side_claim = Claim.create!(
      canonical_text: "Haddad se recusou a conversar com Daniel Vorcaro.",
      canonical_fingerprint: "haddad-vorcaro-side-doc",
      checkability_status: :checkable
    )
    ArticleClaim.create!(
      article:,
      claim: primary_claim,
      role: :headline,
      surface_text: primary_claim.canonical_text,
      importance_score: 1.0,
      title_related: true
    )
    ArticleClaim.create!(
      article:,
      claim: side_claim,
      role: :body,
      surface_text: side_claim.canonical_text,
      importance_score: 0.6,
      title_related: false
    )
    claim = Claim.create!(
      canonical_text: "Resultado fiscal piorou no periodo.",
      canonical_fingerprint: "resultado-fiscal-piorou-doc",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(
      investigation:,
      claim: primary_claim,
      verdict: :supported,
      checkability_status: :checkable
    )
    ClaimAssessment.create!(
      investigation:,
      claim: side_claim,
      verdict: :supported,
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
    assert_includes document, "subjects: haddad"
    assert_includes document, "lead: O texto discute Haddad, impostos, politica fiscal e contas publicas."
    assert_includes document, "Haddad elevou impostos."
    assert_includes document, "Quais foram os resultados fiscais do periodo?"
    refute_includes document, "Daniel Vorcaro"
  end
end
