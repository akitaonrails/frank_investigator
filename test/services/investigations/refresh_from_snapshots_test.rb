require "test_helper"
require "ostruct"

class Investigations::RefreshFromSnapshotsTest < ActiveSupport::TestCase
  test "rebuilds root article claims from the latest snapshot and refreshes source metadata" do
    root = Article.create!(
      url: "https://www1.folha.uol.com.br/vozes/2026/04/haddad-foi-um-bom-ministro.shtml",
      normalized_url: "https://www1.folha.uol.com.br/vozes/2026/04/haddad-foi-um-bom-ministro.shtml",
      host: "www1.folha.uol.com.br",
      title: "Haddad foi um bom ministro",
      body_text: "Texto antigo",
      fetch_status: :fetched,
      source_kind: :news_article,
      source_role: :news_reporting,
      fetched_at: 1.day.ago
    )
    investigation = Investigation.create!(
      submitted_url: root.url,
      normalized_url: root.normalized_url,
      root_article: root,
      status: :completed,
      llm_summary: { "overall_quality" => "old" },
      event_context: { "related_investigations" => [] }
    )

    stale_claim = Claim.create!(
      canonical_text: "Haddad foi um bom ministro.",
      canonical_fingerprint: "stale-evaluative-claim",
      checkability_status: :checkable
    )
    ArticleClaim.create!(article: root, claim: stale_claim, role: :headline, surface_text: stale_claim.canonical_text, importance_score: 1.0)
    ClaimAssessment.create!(investigation:, claim: stale_claim, verdict: :supported, checkability_status: :checkable)

    HtmlSnapshot.store!(article: root, html: snapshot_html, url: root.normalized_url)
    rhetorical = rhetorical_result
    contextual = contextual_result
    coordinated = coordinated_result
    emotional = emotional_result

    with_singleton_override(Analyzers::ClaimExtractor, :call, ->(*, **) { [
      Analyzers::ClaimExtractor::Result.new(
        canonical_text: "Haddad foi um bom ministro.",
        surface_text: "Haddad foi um bom ministro.",
        role: :headline,
        checkability_status: :not_checkable,
        importance_score: 1.0,
        canonical_form: "Haddad foi um bom ministro.",
        semantic_key: "haddad_bom_ministro"
      )
    ] }) do
      with_singleton_override(Analyzers::ClaimDecomposer, :call, ->(*, **) { [
        OpenStruct.new(
          canonical_text: "Haddad foi um bom ministro.",
          checkability_status: :not_checkable,
          claim_kind: :statement,
          entities: {},
          time_scope: nil,
          claim_timestamp_start: nil,
          claim_timestamp_end: nil
        )
      ] }) do
        with_singleton_override(Analyzers::BatchContentAnalyzer, :call, ->(*, **) { {} }) do
          with_singleton_override(Analyzers::RhetoricalFallacyAnalyzer, :call, ->(*, **) { rhetorical }) do
            with_singleton_override(Analyzers::ContextualGapAnalyzer, :call, ->(*, **) { contextual }) do
              with_singleton_override(Analyzers::CoordinatedNarrativeDetector, :call, ->(*, **) { coordinated }) do
                with_singleton_override(Analyzers::EmotionalManipulationScorer, :call, ->(*, **) { emotional }) do
                  with_singleton_override(Investigations::GenerateSummary, :call, ->(*, **) {
                    Investigations::GenerateSummary::Result.new(
                      conclusion: "Resumo",
                      strengths: [],
                      weaknesses: [],
                      overall_quality: "insufficient"
                    )
                  }) do
                    with_singleton_override(Analyzers::HonestHeadlineGenerator, :call, ->(*, **) { "Headline honesta" }) do
                      with_singleton_override(Analyzers::CrossInvestigationEnricher, :call, ->(*, **) { nil }) do
                        Investigations::RefreshFromSnapshots.call(investigation:)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    root.reload
    investigation.reload

    assert_equal "opinion_column", root.source_role
    assert_equal 1, investigation.claim_assessments.count
    assert_equal "not_checkable", investigation.claim_assessments.first.checkability_status
    assert_equal "not_checkable", investigation.claim_assessments.first.verdict
    assert_equal [ "Haddad foi um bom ministro." ], root.claims.pluck(:canonical_text)
    assert_nil investigation.event_context
  end

  private

  def snapshot_html
    <<~HTML
      <html>
        <head>
          <title>Haddad foi um bom ministro</title>
          <meta property="og:type" content="article">
        </head>
        <body>
          <article>
            <h1>Haddad foi um bom ministro</h1>
            <p>Fernando Haddad fez a reforma tributária que poucos acreditavam ser possível, enfrentou resistência política relevante, conduziu negociações longas com estados e municípios e se tornou o centro de um debate público intenso sobre política fiscal, capacidade de articulação e desempenho econômico do governo.</p>
            <p>O texto discute indicadores de desemprego, inflação, crescimento econômico, arrecadação e reação do mercado, sempre em linguagem opinativa e com muitos juízos de valor sobre o legado político do ministro, em vez de se limitar a uma alegação factual única e facilmente verificável.</p>
            <p>Também afirma que a avaliação sobre o ministro depende de quais critérios são escolhidos, como carga tributária, resultado primário, articulação no Congresso, inflação, investimentos e trajetória eleitoral posterior, o que reforça o caráter interpretativo do enquadramento usado no artigo.</p>
          </article>
        </body>
      </html>
    HTML
  end

  def rhetorical_result
    OpenStruct.new(fallacies: [], narrative_bias_score: 0.0, summary: "Sem achados")
  end

  def contextual_result
    OpenStruct.new(gaps: [], completeness_score: 1.0, summary: "Sem lacunas")
  end

  def coordinated_result
    OpenStruct.new(
      coordination_score: 0.0,
      pattern_summary: "Sem coordenação",
      narrative_fingerprint: "none",
      similar_coverage: [],
      convergent_omissions: [],
      convergent_framing: []
    )
  end

  def emotional_result
    OpenStruct.new(
      emotional_temperature: 0.0,
      evidence_density: 1.0,
      manipulation_score: 0.0,
      dominant_emotions: [],
      contributing_factors: [],
      summary: "Sem manipulação"
    )
  end

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
