require "test_helper"

class Sources::UsAuthorityClassifierTest < ActiveSupport::TestCase
  # Tier A: authenticated primary sources

  test "classifies govinfo as authenticated legal text with top authority" do
    result = classify("https://www.govinfo.gov/content/pkg/FR-2025-05-21/pdf/2025-09093.pdf", "www.govinfo.gov", "Executive Order")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
    assert_operator result.authority_score, :>=, 0.99
    assert_equal "govinfo.gov", result.independence_group
  end

  test "classifies congress.gov as authenticated legal text" do
    result = classify("https://www.congress.gov/bill/119th-congress/house-bill/1234", "www.congress.gov", "H.R. 1234")

    assert_equal :legislative_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
    assert_operator result.authority_score, :>=, 0.98
    assert_equal "congress.gov", result.independence_group
  end

  test "classifies federal register as authenticated legal text" do
    result = classify("https://www.federalregister.gov/documents/2025/05/21/2025-09093/example", "www.federalregister.gov", "Final Rule")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies federal reserve as neutral statistics" do
    result = classify("https://www.federalreserve.gov/newsevents/pressreleases/monetary20260311a.htm", "www.federalreserve.gov", "FOMC Statement")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :neutral_statistics, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies FRED as neutral statistics" do
    result = classify("https://fred.stlouisfed.org/series/UNRATE", "fred.stlouisfed.org", "Unemployment Rate")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :neutral_statistics, result.source_role
    assert_operator result.authority_score, :>=, 0.96
  end

  test "classifies BLS as neutral statistics" do
    result = classify("https://www.bls.gov/news.release/empsit.nr0.htm", "www.bls.gov", "Employment Situation")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :neutral_statistics, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies Census as neutral statistics" do
    result = classify("https://data.census.gov/table/ACSDT1Y2023.B01003", "data.census.gov", "Total Population")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :neutral_statistics, result.source_role
    assert_operator result.authority_score, :>=, 0.96
  end

  test "classifies SEC EDGAR as authenticated legal text" do
    result = classify("https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=0001318605", "www.sec.gov", "10-K Filing")

    assert_equal :company_filing, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
    assert_operator result.authority_score, :>=, 0.98
  end

  test "classifies U.S. Courts as authenticated legal text" do
    result = classify("https://www.uscourts.gov/about-federal-courts", "www.uscourts.gov", "About Federal Courts")

    assert_equal :court_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
    assert_operator result.authority_score, :>=, 0.97
  end

  test "classifies PACER as court record" do
    result = classify("https://www.pacer.gov/findcase.html", "www.pacer.gov", "Find a Case")

    assert_equal :court_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :authenticated_legal_text, result.source_role
  end

  # Tier B: primary but political/role-limited

  test "classifies White House as official position with capped authority" do
    result = classify("https://www.whitehouse.gov/briefing-room/statements-releases/2026/example", "www.whitehouse.gov", "Statement")

    assert_equal :government_record, result.source_kind
    assert_equal :secondary, result.authority_tier
    assert_equal :official_position, result.source_role
    assert_operator result.authority_score, :<=, 0.75
    assert_equal "whitehouse.gov", result.independence_group
  end

  # Tier C: independent oversight

  test "classifies GAO as oversight" do
    result = classify("https://www.gao.gov/products/gao-25-1234", "www.gao.gov", "GAO Report")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :oversight, result.source_role
    assert_operator result.authority_score, :>=, 0.96
  end

  test "classifies CBO as oversight" do
    result = classify("https://www.cbo.gov/publication/60000", "www.cbo.gov", "CBO Cost Estimate")

    assert_equal :government_record, result.source_kind
    assert_equal :primary, result.authority_tier
    assert_equal :oversight, result.source_role
    assert_operator result.authority_score, :>=, 0.96
  end

  # Tier D: research discovery

  test "classifies NBER as research discovery" do
    result = classify("https://www.nber.org/papers/w12345", "www.nber.org", "Working Paper")

    assert_equal :scientific_paper, result.source_kind
    assert_equal :secondary, result.authority_tier
    assert_equal :research_discovery, result.source_role
    assert_operator result.authority_score, :<=, 0.80
  end

  # Profile registry integration

  test "uses US profile registry for known hosts" do
    Sources::ProfileRegistry.instance_variable_set(:@load_profiles, nil)

    result = classify("https://www.bls.gov/news.release/empsit.nr0.htm", "www.bls.gov", "Employment Situation")

    assert_equal :neutral_statistics, result.source_role.to_sym
  end

  # Source role is always present

  test "default news articles have news_reporting role" do
    result = classify("https://www.example-news.com/article/12345", "www.example-news.com", "Breaking News")

    assert_equal :news_reporting, result.source_role
  end

  test "press releases have official_position role" do
    result = classify("https://www.prnewswire.com/news-releases/example-123.html", "www.prnewswire.com", "Company Announces")

    assert_equal :official_position, result.source_role
  end

  private

  def classify(url, host, title)
    Sources::ProfileRegistry.instance_variable_set(:@load_profiles, nil)
    Sources::AuthorityClassifier.call(url:, host:, title:)
  end
end
