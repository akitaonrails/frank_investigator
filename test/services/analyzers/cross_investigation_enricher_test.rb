require "test_helper"

class Analyzers::CrossInvestigationEnricherTest < ActiveSupport::TestCase
  test "matches related investigations with shared subject and opposing fiscal framing" do
    root_a = Article.create!(
      url: "https://example.com/a",
      normalized_url: "https://example.com/a",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O artigo argumenta que Haddad foi um bom ministro, mas discute Fazenda, impostos e resultado fiscal.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad foi um bom ministro.",
      canonical_fingerprint: "haddad-bom-ministro",
      checkability_status: :not_checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :not_checkable, checkability_status: :not_checkable)

    root_b = Article.create!(
      url: "https://example.com/b",
      normalized_url: "https://example.com/b",
      host: "example.org",
      title: "Após aumentos de impostos, Haddad deixa Ministério da Fazenda",
      body_text: "A reportagem afirma que Haddad deixou o Ministério da Fazenda após aumentos de impostos e piora do quadro fiscal.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "Após aumentos de impostos, Haddad deixa Ministério da Fazenda.",
      canonical_fingerprint: "haddad-impostos-fazenda",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    assert_includes related, inv_b
  end

  test "matches related investigations when the shared subject is repeated in claims" do
    root_a = Article.create!(
      url: "https://example.com/a2",
      normalized_url: "https://example.com/a2",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute Haddad, impostos e política fiscal.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad elevou impostos.",
      canonical_fingerprint: "haddad-impostos-claim-a2",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :supported, checkability_status: :checkable)

    root_b = Article.create!(
      url: "https://example.com/b2",
      normalized_url: "https://example.com/b2",
      host: "example.org",
      title: "Após aumento de impostos, ministro deixa a Fazenda",
      body_text: "A reportagem diz que Haddad deixou a Fazenda após aumento de impostos e piora fiscal.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b1 = Claim.create!(
      canonical_text: "Haddad deixou o Ministério da Fazenda.",
      canonical_fingerprint: "haddad-fazenda-claim-b2",
      checkability_status: :checkable
    )
    claim_b2 = Claim.create!(
      canonical_text: "Haddad aumentou impostos.",
      canonical_fingerprint: "haddad-impostos-claim-b2",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b1, verdict: :supported, checkability_status: :checkable)
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b2, verdict: :supported, checkability_status: :checkable)

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    assert_includes related, inv_b
  end

  test "matches related investigations when the shared subject appears in strong topic overlap" do
    root_a = Article.create!(
      url: "https://example.com/a3",
      normalized_url: "https://example.com/a3",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute Haddad, carga tributária, política fiscal, gastos e resultado do governo.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad foi um bom ministro.",
      canonical_fingerprint: "haddad-bom-ministro-a3",
      checkability_status: :not_checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :not_checkable, checkability_status: :not_checkable)

    root_b = Article.create!(
      url: "https://example.com/b3",
      normalized_url: "https://example.com/b3",
      host: "example.org",
      title: "O rombo brasileiro já está contratado",
      body_text: "A análise atribui a Haddad aumento de gastos, política fiscal fraca, mais impostos e rombo nas contas públicas.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "O rombo fiscal já está contratado.",
      canonical_fingerprint: "rombo-fiscal-contratado-b3",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    assert_includes related, inv_b
  end

  test "does not match unrelated investigations that only share a public figure" do
    root_a = Article.create!(
      url: "https://example.com/c",
      normalized_url: "https://example.com/c",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute Fazenda, impostos e política fiscal.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad foi um bom ministro.",
      canonical_fingerprint: "haddad-bom-ministro-2",
      checkability_status: :not_checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :not_checkable, checkability_status: :not_checkable)

    root_b = Article.create!(
      url: "https://example.com/d",
      normalized_url: "https://example.com/d",
      host: "example.net",
      title: "Haddad participa de evento sobre educação digital",
      body_text: "A cobertura trata de educação digital, conectividade nas escolas e formação de professores para uso de tecnologia em sala de aula.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "Haddad participou de evento sobre educação digital.",
      canonical_fingerprint: "haddad-educacao-digital",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    refute_includes related, inv_b
  end

  test "does not match unrelated investigations through broad lexical overlap alone" do
    root_a = Article.create!(
      url: "https://example.com/e",
      normalized_url: "https://example.com/e",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute programa, recurso, governo, artigo, texto e política fiscal.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad foi um bom ministro.",
      canonical_fingerprint: "haddad-bom-ministro-3",
      checkability_status: :not_checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :not_checkable, checkability_status: :not_checkable)

    root_b = Article.create!(
      url: "https://example.com/f",
      normalized_url: "https://example.com/f",
      host: "example.news",
      title: "Noelia Castillo recorre para manter direito à eutanásia",
      body_text: "O texto descreve recurso, programa, artigo, governo e texto sobre uma disputa judicial na Espanha.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "Noelia Castillo recorreu para manter o direito à eutanásia.",
      canonical_fingerprint: "noelia-eutanasia",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    refute_includes related, inv_b
  end

  test "does not match investigations that only share generic institutions or media actors" do
    root_a = Article.create!(
      url: "https://example.com/g",
      normalized_url: "https://example.com/g",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto discute política fiscal, impostos e o governo federal.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad foi um bom ministro.",
      canonical_fingerprint: "haddad-bom-ministro-4",
      checkability_status: :not_checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :not_checkable, checkability_status: :not_checkable)
    inv_a.update!(contextual_gaps: {
      "gaps" => [
        { "question" => "O Governo apresentou dados fiscais completos?" }
      ]
    })

    root_b = Article.create!(
      url: "https://example.com/h",
      normalized_url: "https://example.com/h",
      host: "example.tv",
      title: "GloboNews pede desculpas após comentário de Neide Duarte",
      body_text: "A reportagem trata da GloboNews, do governo e de repercussões editoriais.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "GloboNews pediu desculpas após comentário de Neide Duarte.",
      canonical_fingerprint: "globonews-neide-duarte",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)
    inv_b.update!(contextual_gaps: {
      "gaps" => [
        { "question" => "A GloboNews corrigiu a informação exibida?" }
      ]
    })

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    refute_includes related, inv_b
  end

  test "does not match on a side subject that only appears inside a claim" do
    root_a = Article.create!(
      url: "https://example.com/i",
      normalized_url: "https://example.com/i",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "O texto cita Daniel Vorcaro apenas como episódio lateral dentro de uma avaliação sobre Haddad.",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad se recusou a conversar com Daniel Vorcaro.",
      canonical_fingerprint: "haddad-vorcaro-side-claim",
      checkability_status: :checkable
    )
    ArticleClaim.create!(
      article: root_a,
      claim: claim_a,
      role: :body,
      surface_text: claim_a.canonical_text,
      importance_score: 0.6,
      title_related: false
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :supported, checkability_status: :checkable)

    root_b = Article.create!(
      url: "https://example.com/j",
      normalized_url: "https://example.com/j",
      host: "example.tv",
      title: "GloboNews pede desculpas por associação incorreta entre Vorcaro e o PT",
      body_text: "A reportagem é sobre Daniel Vorcaro, GloboNews e o Banco Master.",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "Daniel Vorcaro foi associado incorretamente ao PT.",
      canonical_fingerprint: "vorcaro-pt-associacao",
      checkability_status: :checkable
    )
    ArticleClaim.create!(
      article: root_b,
      claim: claim_b,
      role: :headline,
      surface_text: claim_b.canonical_text,
      importance_score: 1.0,
      title_related: true
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)

    related = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a).send(:find_related_investigations)

    refute_includes related, inv_b
  end

  test "builds heuristic composite when llm is unavailable" do
    root_a = Article.create!(
      url: "https://example.com/a",
      normalized_url: "https://example.com/a",
      host: "example.com",
      title: "Relato A",
      body_text: "Texto A",
      fetch_status: :fetched
    )
    inv_a = Investigation.create!(submitted_url: root_a.url, normalized_url: root_a.normalized_url, root_article: root_a, status: :completed)
    claim_a = Claim.create!(
      canonical_text: "Haddad elevou impostos.",
      canonical_fingerprint: "haddad-impostos-1",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_a, claim: claim_a, verdict: :supported, checkability_status: :checkable)

    root_b = Article.create!(
      url: "https://example.org/b",
      normalized_url: "https://example.org/b",
      host: "example.org",
      title: "Relato B",
      body_text: "Texto B",
      fetch_status: :fetched
    )
    inv_b = Investigation.create!(submitted_url: root_b.url, normalized_url: root_b.normalized_url, root_article: root_b, status: :completed)
    claim_b = Claim.create!(
      canonical_text: "Haddad deixou o ministério.",
      canonical_fingerprint: "haddad-ministerio-1",
      checkability_status: :checkable
    )
    ClaimAssessment.create!(investigation: inv_b, claim: claim_b, verdict: :supported, checkability_status: :checkable)

    enricher = Analyzers::CrossInvestigationEnricher.new(investigation: inv_a)
    enricher.define_singleton_method(:llm_available?) { false }

    composite = enricher.send(:build_composite, [ inv_a, inv_b ])

    assert_includes composite[:composite_timeline], "Haddad elevou impostos."
    assert_includes composite[:coverage_map].map { |c| c[:host] }, "example.com"
    assert_includes composite[:critical_omissions], "Haddad deixou o ministério."
  end
end
