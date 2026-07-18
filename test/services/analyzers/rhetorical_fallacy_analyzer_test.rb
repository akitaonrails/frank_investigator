require "test_helper"

class RhetoricalFallacyAnalyzerTest < ActiveSupport::TestCase
  setup do
    @article = Article.create!(
      url: "https://news.com/rhetoric-test",
      normalized_url: "https://news.com/rhetoric-test-#{SecureRandom.hex(4)}",
      host: "news.com",
      title: "Crime statistics show improvement",
      fetch_status: :fetched,
      body_text: ""
    )
    @investigation = Investigation.create!(
      submitted_url: @article.url,
      normalized_url: @article.normalized_url,
      root_article: @article,
      status: :processing
    )
    @claim = Claim.create!(
      canonical_text: "Crime fell 5% in Dallas over the past 6 months",
      canonical_fingerprint: "rhetoric_#{SecureRandom.hex(4)}",
      checkability_status: :checkable,
      first_seen_at: Time.current,
      last_seen_at: Time.current
    )
    @assessment = ClaimAssessment.create!(
      investigation: @investigation,
      claim: @claim,
      verdict: :supported,
      confidence_score: 0.85,
      authority_score: 0.8
    )
  end

  test "heuristic detects bait-and-pivot pattern" do
    @article.update!(body_text:
      "Police report data for Dallas shows crime fell 5% consistently " \
      "every month for the past 6 months. The statistics are clear and " \
      "verified by multiple agencies. But you know that the president " \
      "condones acts of violence and this country is going downhill."
    )

    without_llm do
      result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
      assert result.fallacies.any? { |f| f.type == "bait_and_pivot" }
      assert_operator result.narrative_bias_score, :>, 0
    end
  end

  test "heuristic detects appeal to authority over data" do
    @article.update!(body_text:
      "Fed data shows that inflation came down again for the 4th consecutive " \
      "month, reaching its lowest level since 2020. However, in my long career " \
      "as an economist, I know it will go up again in no time. These numbers " \
      "don't tell the real story."
    )

    without_llm do
      result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
      types = result.fallacies.map(&:type)
      assert types.include?("bait_and_pivot") || types.include?("appeal_to_authority"),
        "Expected bait_and_pivot or appeal_to_authority but got: #{types}"
      assert_operator result.narrative_bias_score, :>, 0
    end
  end

  test "no fallacies for straight factual reporting" do
    @article.update!(body_text:
      "Police report data for Dallas shows crime fell 5% consistently " \
      "every month for the past 6 months. The statistics cover violent crime, " \
      "property crime, and misdemeanors across all precincts. Data was compiled " \
      "from official police records filed in the Dallas County system."
    )

    without_llm do
      result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
      assert_empty result.fallacies
      assert_operator result.narrative_bias_score, :<=, 0.1, "Factual reporting should have near-zero bias score"
    end
  end

  test "empty result when no assessed claims" do
    @assessment.destroy!

    result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
    assert_empty result.fallacies
    assert_equal 0.0, result.narrative_bias_score
  end

  test "empty result when article has no body" do
    @article.update!(body_text: nil)

    result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
    assert_empty result.fallacies
  end

  test "heuristic detects Portuguese pivot pattern" do
    @article.update!(body_text:
      "Os dados do IBGE mostram que a economia cresceu 3,1% no trimestre, " \
      "um resultado acima das expectativas do mercado. Os números confirmam " \
      "a tendência positiva. Mas, apesar dos números, o governo continua " \
      "destruindo o país com suas políticas irresponsáveis."
    )

    without_llm do
      result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
      assert result.fallacies.any? { |f| f.type == "bait_and_pivot" }
    end
  end

  test "result struct has expected fields" do
    result = Analyzers::RhetoricalFallacyAnalyzer::Result.new(
      fallacies: [],
      narrative_bias_score: 0.3,
      summary: "Test"
    )

    assert_equal 0.3, result.narrative_bias_score
    assert_equal "Test", result.summary
    assert_empty result.fallacies
  end

  test "fallacy types constant covers key categories" do
    types = Analyzers::RhetoricalFallacyAnalyzer::FALLACY_TYPES

    assert_includes types, "bait_and_pivot"
    assert_includes types, "appeal_to_authority"
    assert_includes types, "false_cause"
    assert_includes types, "strawman"
    assert_includes types, "anecdote_over_data"
    assert_includes types, "loaded_language"
    assert_includes types, "ad_hominem"
    assert_includes types, "cherry_picking"
    assert_includes types, "delegitimizing_reframing"
  end

  test "response schema and parsing support delegitimizing reframing" do
    analyzer = Analyzers::RhetoricalFallacyAnalyzer.new(investigation: @investigation)
    schema = analyzer.send(:response_schema)
    type_enum = schema.dig(:schema, :properties, :fallacies, :items, :properties, :type, :enum)
    assert_includes type_enum, "delegitimizing_reframing"

    result = analyzer.send(:parse_response, {
      "fallacies" => [ {
        "type" => "delegitimizing_reframing",
        "severity" => "medium",
        "excerpt" => "The minister's statement was dismissed as a conspiracy theory.",
        "explanation" => "The label substitutes for an evaluation of the stated evidence.",
        "undermined_claim_index" => 0
      } ],
      "narrative_bias_score" => 0.4,
      "summary" => "The article treats a label as adjudication."
    })

    assert_equal "delegitimizing_reframing", result.fallacies.first.type
    assert_equal @claim.canonical_text, result.fallacies.first.undermined_claim
  end

  test "prompt carries evidence source-role metadata" do
    evidence_article = Article.create!(
      url: "https://agency.gov/statement",
      normalized_url: "https://agency.gov/statement-#{SecureRandom.hex(4)}",
      host: "agency.gov",
      title: "Agency statement",
      fetch_status: :fetched,
      source_role: :official_position,
      authority_tier: :primary
    )
    EvidenceItem.create!(
      claim_assessment: @assessment,
      article: evidence_article,
      source_url: evidence_article.url,
      stance: :supports
    )

    analyzer = Analyzers::RhetoricalFallacyAnalyzer.new(investigation: @investigation)
    prompt = JSON.parse(analyzer.send(:build_prompt, @article))

    assert_equal "official_position", prompt.dig("assessed_claims", 0, "evidence_sources", 0, "source_role")
    assert_includes Analyzers::RhetoricalFallacyAnalyzer::SYSTEM_PROMPT_TEMPLATE, "NOT proof that"
  end

  test "degraded mode does not flag attributed criticism with independent rebuttal" do
    @article.update!(body_text:
      "The columnist called the minister's proposal a conspiracy theory. A court filing " \
      "and independently audited statistics were then reviewed; both contradicted parts " \
      "of the proposal, while the report said the remaining question was unresolved."
    )

    without_llm do
      result = Analyzers::RhetoricalFallacyAnalyzer.call(investigation: @investigation)
      refute_includes result.fallacies.map(&:type), "delegitimizing_reframing"
      assert_empty result.fallacies
    end
  end

  private

  def without_llm
    saved = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = nil
    yield
  ensure
    ENV["OPENROUTER_API_KEY"] = saved
  end
end
