require "test_helper"

class Sources::BrazilConnectorsTest < ActiveSupport::TestCase
  test "extracts bill metadata from brazil legislative pages" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.camara.leg.br/noticias/1234-projeto-de-lei-avanca/",
      host: "www.camara.leg.br",
      title: "PL 1234/2026 avanca no plenario",
      html: <<~HTML,
        <html>
          <head>
            <meta property="og:site_name" content="Camara dos Deputados">
            <meta property="article:published_time" content="2026-03-11T13:00:00-03:00">
          </head>
          <body>
            <article>
              <p>O PL 1234/2026 foi aprovado no plenario.</p>
            </article>
          </body>
        </html>
      HTML
      source_kind: :legislative_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :legislative_record, result.source_kind
    assert_equal "brazil_legislative", result.metadata_json["connector"]
    assert_equal "PL 1234/2026", result.metadata_json["bill_reference"]
  end

  test "extracts case metadata from brazil court pages" do
    result = Sources::ConnectorRouter.call(
      url: "https://portal.stf.jus.br/noticias/verNoticiaDetalhe.asp?idConteudo=123",
      host: "portal.stf.jus.br",
      title: "Ministro Alexandre decide no processo 1234567-89.2026.1.01.0001",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="STF"></head>
          <body>
            <article>
              <p>O relator ministro Alexandre votou no processo 1234567-89.2026.1.01.0001.</p>
            </article>
          </body>
        </html>
      HTML
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :court_record, result.source_kind
    assert_equal "brazil_court", result.metadata_json["connector"]
    assert_equal "1234567-89.2026.1.01.0001", result.metadata_json["case_number"]
  end

  test "extracts ticker and filing type from brazil market filings" do
    result = Sources::ConnectorRouter.call(
      url: "https://ri.example.com.br/fato-relevante-petr4",
      host: "ri.example.com.br",
      title: "Fato relevante PETR4",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="RI Example"></head>
          <body>
            <article>
              <p>Companhia divulga fato relevante PETR4 ao mercado.</p>
            </article>
          </body>
        </html>
      HTML
      source_kind: :company_filing,
      authority_tier: :primary,
      authority_score: 0.92
    )

    assert_equal :company_filing, result.source_kind
    assert_equal "brazil_market_filing", result.metadata_json["connector"]
    assert_equal "PETR4", result.metadata_json["ticker"]
    assert_match(/fato relevante/i, result.metadata_json["filing_type"])
  end
end
