require "test_helper"

class Sources::BrazilDeepConnectorsTest < ActiveSupport::TestCase
  setup do
    Sources::ProfileRegistry.instance_variable_set(:@load_profiles, nil)
  end

  # Gazette connector tests

  test "gazette connector extracts DOU section and act reference" do
    result = route(
      url: "https://www.in.gov.br/web/dou/-/decreto-12345",
      host: "www.in.gov.br",
      title: "Decreto 12345 de 10 de marco de 2026",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="Diario Oficial da Uniao"></head>
          <body>
            <p>Seção 1</p>
            <p>Decreto 12345 altera regras sobre importação.</p>
            <p>Publicado em 10 de março de 2026.</p>
          </body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.99
    )

    assert_equal :government_record, result.source_kind
    assert_equal "brazil_gazette", result.metadata_json["connector"]
    assert_equal "authenticated_legal_text", result.metadata_json["source_role"]
    assert_equal "federal", result.metadata_json["gazette_scope"]
    assert_match(/Se[cç][aã]o\s*1/i, result.metadata_json["section"])
    assert_match(/Decreto/, result.metadata_json["act_reference"])
  end

  test "gazette connector identifies state gazette scope" do
    result = route(
      url: "https://diariooficial.sp.gov.br/exemplo",
      host: "diariooficial.sp.gov.br",
      title: "DOE SP",
      html: "<html><body><p>Portaria 456 do Secretario de Saude.</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.99
    )

    assert_equal "brazil_gazette", result.metadata_json["connector"]
    assert_equal "state", result.metadata_json["gazette_scope"]
  end

  # Statistics connector tests

  test "statistics connector extracts IBGE indicator" do
    result = route(
      url: "https://www.ibge.gov.br/indicadores/ipca",
      host: "www.ibge.gov.br",
      title: "IPCA acumula alta de 4,5% em 12 meses",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="IBGE"></head>
          <body><p>O IPCA de fevereiro foi de 0,83%. Pesquisa Nacional de Precos ao Consumidor.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :government_record, result.source_kind
    assert_equal "brazil_statistics", result.metadata_json["connector"]
    assert_equal "neutral_statistics", result.metadata_json["source_role"]
    assert_equal "IBGE", result.metadata_json["agency"]
    assert_equal "statistics", result.metadata_json["statistical_domain"]
    assert_equal "IPCA", result.metadata_json["indicator"]
  end

  test "statistics connector identifies Ipea agency" do
    result = route(
      url: "https://www.ipea.gov.br/portal/publicacao/exemplo",
      host: "www.ipea.gov.br",
      title: "Nota Tecnica Ipea sobre PIB",
      html: "<html><body><p>Estimativa do PIB para o trimestre mostra crescimento.</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.93
    )

    assert_equal "Ipea", result.metadata_json["agency"]
    assert_equal "economic_research", result.metadata_json["statistical_domain"]
    assert_equal "PIB", result.metadata_json["indicator"]
  end

  test "statistics connector identifies DataSUS" do
    result = route(
      url: "https://datasus.saude.gov.br/informacoes-de-saude",
      host: "datasus.saude.gov.br",
      title: "Indicadores de mortalidade",
      html: "<html><body><p>Censo hospitalar e indicadores de mortalidade.</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.95
    )

    assert_equal "DataSUS", result.metadata_json["agency"]
    assert_equal "health_statistics", result.metadata_json["statistical_domain"]
  end

  # Regulator connector tests

  test "regulator connector extracts BCB resolution" do
    result = route(
      url: "https://www.bcb.gov.br/estabilidadefinanceira/resolucao123",
      host: "www.bcb.gov.br",
      title: "Resolucao BCB 123",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="Banco Central do Brasil"></head>
          <body><p>Resolução nº 123 altera regras sobre capital mínimo.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :government_record, result.source_kind
    assert_equal "brazil_regulator", result.metadata_json["connector"]
    assert_equal "neutral_statistics", result.metadata_json["source_role"]
    assert_equal "Banco Central do Brasil", result.metadata_json["agency"]
    assert_equal "monetary_financial", result.metadata_json["regulatory_domain"]
    assert_match(/Resolu/, result.metadata_json["resolution_reference"])
  end

  test "regulator connector identifies TCU as oversight" do
    result = route(
      url: "https://portal.tcu.gov.br/acordao/12345",
      host: "portal.tcu.gov.br",
      title: "Acordao TCU 12345/2026",
      html: "<html><body><p>O TCU determinou que o orgao corrija irregularidades.</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "brazil_regulator", result.metadata_json["connector"]
    assert_equal "oversight", result.metadata_json["source_role"]
    assert_equal "TCU", result.metadata_json["agency"]
    assert_equal "oversight_audit", result.metadata_json["regulatory_domain"]
  end

  test "regulator connector identifies Anvisa" do
    result = route(
      url: "https://www.anvisa.gov.br/noticias/resolucao-rdc",
      host: "www.anvisa.gov.br",
      title: "Anvisa aprova nova resolucao sobre rotulagem",
      html: "<html><body><p>Resolução RDC 789 estabelece novas regras de rotulagem nutricional.</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.95
    )

    assert_equal "Anvisa", result.metadata_json["agency"]
    assert_equal "health_regulatory", result.metadata_json["regulatory_domain"]
  end

  test "regulator connector extracts CNPJ" do
    result = route(
      url: "https://www.bcb.gov.br/exemplo",
      host: "www.bcb.gov.br",
      title: "Consulta instituicao",
      html: "<html><body><p>Instituicao: Banco XYZ S.A. CNPJ: 12.345.678/0001-90</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "12.345.678/0001-90", result.metadata_json["cnpj"]
  end

  # Enhanced court connector tests

  test "enhanced court connector extracts action type and court level" do
    result = route(
      url: "https://portal.stf.jus.br/processos/detalhe.asp?incidente=1234",
      host: "portal.stf.jus.br",
      title: "ADI 7654 - Acao Direta de Inconstitucionalidade",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="STF"></head>
          <body>
            <p>ADI 7654 questiona a constitucionalidade da lei.</p>
            <p>Relator Ministro Alexandre de Moraes.</p>
            <p>Processo 0000001-23.2026.1.00.0000</p>
            <p>Acordão publicado no DJe 15/03/2026.</p>
          </body>
        </html>
      HTML
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :court_record, result.source_kind
    assert_equal "brazil_court", result.metadata_json["connector"]
    assert_equal "STF", result.metadata_json["court"]
    assert_equal "supreme", result.metadata_json["court_level"]
    assert_match(/ADI 7654/, result.metadata_json["action_type"])
    assert_match(/Ministro Alexandre/, result.metadata_json["rapporteur"])
    assert_equal "0000001-23.2026.1.00.0000", result.metadata_json["case_number"]
    assert_match(/acordão/i, result.metadata_json["ruling_type"])
    assert_match(/DJe/, result.metadata_json["publication_reference"])
  end

  test "court connector identifies TRF level" do
    result = route(
      url: "https://www.trf1.jus.br/noticias/exemplo",
      host: "www.trf1.jus.br",
      title: "TRF1 decide sobre recurso",
      html: "<html><body><p>Desembargador Federal decide no HC 12345.</p></body></html>",
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "TRF1", result.metadata_json["court"]
    assert_equal "federal_regional", result.metadata_json["court_level"]
  end

  test "court connector identifies state court" do
    result = route(
      url: "https://www.tjsp.jus.br/noticias/exemplo",
      host: "www.tjsp.jus.br",
      title: "TJSP julga recurso",
      html: "<html><body><p>Desembargadora relatora votou pela procedencia.</p></body></html>",
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "TJSP", result.metadata_json["court"]
    assert_equal "state", result.metadata_json["court_level"]
  end

  # Enhanced legislative connector tests

  test "enhanced legislative connector extracts law reference and chamber" do
    result = route(
      url: "https://www.camara.leg.br/noticias/1234",
      host: "www.camara.leg.br",
      title: "Lei Complementar 200/2026 aprovada",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="Camara dos Deputados"></head>
          <body>
            <p>O PL 5678/2025 que deu origem foi relatado na CCJ.</p>
            <p>A Lei Complementar 200/2026 foi aprovada no plenário por 300 votos a favor.</p>
          </body>
        </html>
      HTML
      source_kind: :legislative_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "brazil_legislative", result.metadata_json["connector"]
    assert_equal "camara", result.metadata_json["chamber"]
    assert_match(/Lei Complementar/, result.metadata_json["law_reference"])
    assert_match(/PL 5678\/2025/, result.metadata_json["bill_reference"])
    assert_equal "CCJ", result.metadata_json["commission"]
    assert_match(/aprovad/, result.metadata_json["vote_status"])
  end

  # Authority classifier tests for new patterns

  test "classifies DOU as authenticated legal text with top authority" do
    result = Sources::AuthorityClassifier.call(
      url: "https://www.in.gov.br/web/dou/-/decreto-123",
      host: "www.in.gov.br",
      title: "Decreto"
    )

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
    assert_operator result.authority_score, :>=, 0.99
  end

  test "classifies IBGE as neutral statistics" do
    result = Sources::AuthorityClassifier.call(
      url: "https://www.ibge.gov.br/indicadores",
      host: "www.ibge.gov.br",
      title: "IPCA"
    )

    assert_equal :neutral_statistics, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies BCB as neutral statistics" do
    result = Sources::AuthorityClassifier.call(
      url: "https://www.bcb.gov.br/copom",
      host: "www.bcb.gov.br",
      title: "Selic"
    )

    assert_equal :neutral_statistics, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies TCU as oversight" do
    result = Sources::AuthorityClassifier.call(
      url: "https://portal.tcu.gov.br/acordao/123",
      host: "portal.tcu.gov.br",
      title: "Acordao"
    )

    assert_equal :oversight, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies Anvisa as primary regulator" do
    result = Sources::AuthorityClassifier.call(
      url: "https://www.anvisa.gov.br/resolucao",
      host: "www.anvisa.gov.br",
      title: "RDC"
    )

    assert_equal :primary, result.authority_tier
    assert_operator result.authority_score, :>=, 0.95
  end

  private

  def route(url:, host:, title:, html:, source_kind:, authority_tier:, authority_score:)
    Sources::ConnectorRouter.call(url:, host:, title:, html:, source_kind:, authority_tier:, authority_score:)
  end
end
