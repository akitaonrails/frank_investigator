require "test_helper"

class HeadlineDivergenceTest < ActiveSupport::TestCase
  test "detects escalation when headline accuses but body only has claims" do
    result = Analyzers::HeadlineBaitAnalyzer.call(
      title: "Celebrity X accused of domestic violence against woman",
      body_text: "According to an unnamed neighbor who claimed to have heard screams, " \
                 "Celebrity X was allegedly involved in a dispute. No police report has " \
                 "been filed and the celebrity has not responded to requests for comment. " \
                 "The claims could not be independently verified."
    )

    assert_operator result.score, :>, 40
    assert_operator result.definitive_claims, :>, 0
    assert_operator result.hedging_signals, :>, 0
    assert_match(/does not substantiate/, result.reason)
  end

  test "low score when headline matches body substance" do
    result = Analyzers::HeadlineBaitAnalyzer.call(
      title: "Federal Reserve raises interest rates by 0.25%",
      body_text: "The Federal Reserve announced today that it would raise interest " \
                 "rates by 0.25 percentage points, bringing the federal funds rate " \
                 "to 5.5%. Chair Powell stated the decision was unanimous."
    )

    assert_operator result.score, :<, 30
    assert_equal 0, result.hedging_signals
  end

  test "detects Portuguese hedging patterns" do
    result = Analyzers::HeadlineBaitAnalyzer.call(
      title: "Político acusado de fraude em licitação",
      body_text: "Segundo fontes que não quiseram se identificar, o político " \
                 "supostamente teria participado de um esquema. A informação " \
                 "não foi confirmada pela assessoria do parlamentar e não há " \
                 "registro de boletim de ocorrência sobre o caso."
    )

    assert_operator result.score, :>, 30
    assert_operator result.hedging_signals, :>, 0
  end

  test "high divergence discounts authority in evidence packet" do
    penalty = Analyzers::EvidencePacketBuilder::HEADLINE_DIVERGENCE_AUTHORITY_PENALTY
    builder = Analyzers::EvidencePacketBuilder.new(
      investigation: Investigation.new,
      claim: Claim.new
    )

    # 80% divergence should produce a meaningful penalty
    penalized = builder.send(:apply_headline_penalty, 0.70, 0.80)
    assert_operator penalized, :<, 0.70
    assert_operator penalized, :>, 0.0

    # 20% divergence (below threshold) should not penalize
    unpenalized = builder.send(:apply_headline_penalty, 0.70, 0.20)
    assert_equal 0.70, unpenalized
  end
end

class HeadlineCitationDetectorTest < ActiveSupport::TestCase
  test "detects headline-only citation between articles" do
    art_a = Article.create!(
      url: "https://gossip.com/scandal", normalized_url: "https://gossip.com/scandal-#{SecureRandom.hex(4)}",
      host: "gossip.com", fetch_status: :fetched,
      title: "Major celebrity caught in massive corruption scandal",
      body_text: "According to unnamed sources, the celebrity was allegedly involved. " \
                 "No charges have been filed. The claims could not be independently verified. " \
                 "Representatives have not responded to requests for comment."
    )
    art_b = Article.create!(
      url: "https://news2.com/followup", normalized_url: "https://news2.com/followup-#{SecureRandom.hex(4)}",
      host: "news2.com", fetch_status: :fetched,
      title: "Celebrity corruption confirmed by multiple outlets",
      body_text: "As reported by gossip.com, a major celebrity was caught in a massive " \
                 "corruption scandal. Multiple outlets have now picked up the story. " \
                 "The celebrity has been trending on social media since the revelation."
    )

    result = Analyzers::HeadlineCitationDetector.call(articles: [art_a, art_b])

    assert_operator result.headline_citations.size, :>=, 1
    assert_operator result.amplification_score, :>, 0
  end

  test "no headline citation when body includes qualifying content" do
    art_a = Article.create!(
      url: "https://news.com/report", normalized_url: "https://news.com/report-#{SecureRandom.hex(4)}",
      host: "news.com", fetch_status: :fetched,
      title: "Government passes new education reform bill",
      body_text: "The government has passed a new education reform bill that will " \
                 "affect thousands of schools nationwide. The bill was approved with " \
                 "bipartisan support after months of debate."
    )
    art_b = Article.create!(
      url: "https://edu.com/analysis", normalized_url: "https://edu.com/analysis-#{SecureRandom.hex(4)}",
      host: "edu.com", fetch_status: :fetched,
      title: "Analysis of the new education reform",
      body_text: "Following the government passing the new education reform bill, " \
                 "experts weigh in. The bill was approved with bipartisan support and " \
                 "will affect thousands of schools. The debate lasted months."
    )

    result = Analyzers::HeadlineCitationDetector.call(articles: [art_a, art_b])
    assert_empty result.headline_citations
  end

  test "amplification score scales with citation count" do
    result_struct = Analyzers::HeadlineCitationDetector::Result

    single = result_struct.new(headline_citations: [1], amplification_score: 0.25)
    assert_equal 0.25, single.amplification_score

    # Score from the detector itself
    empty = Analyzers::HeadlineCitationDetector.call(articles: [])
    assert_equal 0.0, empty.amplification_score
  end
end
