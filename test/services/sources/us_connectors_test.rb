require "test_helper"

class Sources::UsConnectorsTest < ActiveSupport::TestCase
  test "us government connector extracts executive order reference from govinfo" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.govinfo.gov/content/pkg/FR-2025-05-21/pdf/2025-09093.pdf",
      host: "www.govinfo.gov",
      title: "Executive Order 14110 on AI",
      html: <<~HTML,
        <html>
          <head>
            <meta property="og:site_name" content="GovInfo">
            <meta property="article:published_time" content="2025-05-21T00:00:00Z">
          </head>
          <body><p>Executive Order 14110 on the Safe, Secure, and Trustworthy Development of AI.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.99
    )

    assert_equal :government_record, result.source_kind
    assert_equal "us_government", result.metadata_json["connector"]
    assert_equal "authenticated_legal_text", result.metadata_json["source_role"]
    assert_match(/Executive Order/, result.metadata_json["document_reference"])
  end

  test "us government connector extracts FR citation" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.federalregister.gov/documents/2025/05/21/2025-09093/example",
      host: "www.federalregister.gov",
      title: "Final Rule on Import Tariffs",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="Federal Register"></head>
          <body><p>Published in 90 FR 12345. This Final Rule establishes new import tariffs.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "us_government", result.metadata_json["connector"]
    assert_equal "90 FR 12345", result.metadata_json["fr_citation"]
    assert_match(/Final Rule/, result.metadata_json["document_reference"])
  end

  test "us government connector identifies whitehouse as official position" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.whitehouse.gov/briefing-room/statements-releases/2026/03/example",
      host: "www.whitehouse.gov",
      title: "President Signs Executive Order",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="The White House"></head>
          <body><p>The President today signed Executive Order on Infrastructure.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :secondary,
      authority_score: 0.72
    )

    assert_equal "us_government", result.metadata_json["connector"]
    assert_equal "official_position", result.metadata_json["source_role"]
    assert_operator result.authority_score, :<=, 0.75
  end

  test "us government connector routes congress.gov as legislative record" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.congress.gov/bill/119th-congress/house-bill/1234",
      host: "www.congress.gov",
      title: "H.R. 1234 - Example Bill",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="Congress.gov"></head>
          <body><p>H.R. 1234 was introduced on March 1, 2026. Public Law 119-42 enacted.</p></body>
        </html>
      HTML
      source_kind: :legislative_record,
      authority_tier: :primary,
      authority_score: 0.98
    )

    assert_equal :legislative_record, result.source_kind
    assert_equal "us_government", result.metadata_json["connector"]
    assert_match(/H\.R\.|Public Law/, result.metadata_json["document_reference"])
  end

  test "us court connector extracts case number" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.uscourts.gov/case/1:24-cv-01234",
      host: "www.uscourts.gov",
      title: "Smith v. Jones",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="U.S. Courts"></head>
          <body><p>In the matter of Case No. 1:24-cv-01234, the court finds...</p></body>
        </html>
      HTML
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :court_record, result.source_kind
    assert_equal "us_court", result.metadata_json["connector"]
    assert_equal "authenticated_legal_text", result.metadata_json["source_role"]
    assert_match(/1:24-cv-01234/, result.metadata_json["case_number"])
  end

  test "us court connector extracts docket reference" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.pacer.gov/case-detail",
      host: "www.pacer.gov",
      title: "United States v. Doe",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="PACER"></head>
          <body><p>Docket No. 2:25-cr-00567-ABC, filed in the Southern District.</p></body>
        </html>
      HTML
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "us_court", result.metadata_json["connector"]
    assert_includes result.metadata_json["docket_reference"], "Docket No."
  end

  test "us sec filing connector extracts 10-K filing type and CIK" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=0001318605&type=10-K",
      host: "www.sec.gov",
      title: "Tesla Inc 10-K Annual Report",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="SEC EDGAR"></head>
          <body>
            <p>Filing type: 10-K for fiscal year ending December 31, 2025.</p>
            <p>CIK: 0001318605</p>
            <p>Accession Number: 0001318605-26-000012</p>
          </body>
        </html>
      HTML
      source_kind: :company_filing,
      authority_tier: :primary,
      authority_score: 0.98
    )

    assert_equal :company_filing, result.source_kind
    assert_equal "us_sec_filing", result.metadata_json["connector"]
    assert_equal "authenticated_legal_text", result.metadata_json["source_role"]
    assert_equal "10-K", result.metadata_json["filing_type"]
    assert_equal "0001318605", result.metadata_json["cik"]
    assert_equal "0001318605-26-000012", result.metadata_json["accession_number"]
  end

  test "us sec filing connector extracts 8-K" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.sec.gov/Archives/edgar/data/0000320193/8-K.htm",
      host: "www.sec.gov",
      title: "Apple Inc 8-K Current Report",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="SEC EDGAR"></head>
          <body><p>Current report on Form 8-K filed by Apple Inc.</p></body>
        </html>
      HTML
      source_kind: :company_filing,
      authority_tier: :primary,
      authority_score: 0.98
    )

    assert_equal "8-K", result.metadata_json["filing_type"]
  end

  test "us statistics connector extracts BLS release name" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.bls.gov/news.release/empsit.nr0.htm",
      host: "www.bls.gov",
      title: "Employment Situation Summary",
      html: <<~HTML,
        <html>
          <head>
            <meta property="og:site_name" content="Bureau of Labor Statistics">
            <meta property="article:published_time" content="2026-03-07T08:30:00-05:00">
          </head>
          <body>
            <p>Total nonfarm payroll employment rose by 200,000 in February.</p>
            <p>The unemployment rate was unchanged at 4.1 percent.</p>
          </body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal :government_record, result.source_kind
    assert_equal "us_statistics", result.metadata_json["connector"]
    assert_equal "neutral_statistics", result.metadata_json["source_role"]
    assert_equal "BLS", result.metadata_json["data_agency"]
    assert_match(/Employment Situation|Unemployment/i, result.metadata_json["release_name"])
  end

  test "us statistics connector identifies Census agency" do
    result = Sources::ConnectorRouter.call(
      url: "https://data.census.gov/table/ACSDT1Y2023.B01003",
      host: "data.census.gov",
      title: "Total Population ACS",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="U.S. Census Bureau"></head>
          <body><p>American Community Survey 1-Year estimates for total population.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.96
    )

    assert_equal "Census", result.metadata_json["data_agency"]
    assert_match(/ACS|American Community Survey/i, result.metadata_json["release_name"])
  end

  test "us statistics connector extracts FRED series ID" do
    result = Sources::ConnectorRouter.call(
      url: "https://fred.stlouisfed.org/series/UNRATE",
      host: "fred.stlouisfed.org",
      title: "Unemployment Rate",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="FRED"></head>
          <body><p>Series UNRATE: Civilian Unemployment Rate, seasonally adjusted.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.96
    )

    assert_equal "FRED", result.metadata_json["data_agency"]
    assert_equal "UNRATE", result.metadata_json["series_id"]
    assert_match(/Unemployment/i, result.metadata_json["release_name"])
  end

  test "us statistics connector identifies Federal Reserve" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.federalreserve.gov/releases/h15/",
      host: "www.federalreserve.gov",
      title: "Selected Interest Rates",
      html: <<~HTML,
        <html>
          <head><meta property="og:site_name" content="Board of Governors"></head>
          <body><p>The Federal Reserve Board releases selected interest rates daily.</p></body>
        </html>
      HTML
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "Federal Reserve", result.metadata_json["data_agency"]
  end

  # Routing correctness

  test "brazil court hosts still route to brazil court connector" do
    result = Sources::ConnectorRouter.call(
      url: "https://portal.stf.jus.br/noticias/verNoticiaDetalhe.asp?idConteudo=123",
      host: "portal.stf.jus.br",
      title: "STF julga acao",
      html: "<html><body><p>O relator ministro Alexandre votou no processo 1234567-89.2026.1.01.0001.</p></body></html>",
      source_kind: :court_record,
      authority_tier: :primary,
      authority_score: 0.97
    )

    assert_equal "brazil_court", result.metadata_json["connector"]
  end

  test "generic government hosts still route to government record connector" do
    result = Sources::ConnectorRouter.call(
      url: "https://www.gov.uk/government/publications/example",
      host: "www.gov.uk",
      title: "UK Government Publication",
      html: "<html><body><p>The government announces a new policy.</p></body></html>",
      source_kind: :government_record,
      authority_tier: :primary,
      authority_score: 0.98
    )

    assert_equal "government_record", result.metadata_json["connector"]
  end
end
