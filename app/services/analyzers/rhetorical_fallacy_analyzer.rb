module Analyzers
  # Analyzes the rhetorical structure of an article against its assessed claims.
  #
  # Detects when an article presents factual data (especially high-confidence
  # supported claims) but then uses logical fallacies to reframe, undermine,
  # or redirect the reader toward a different narrative.
  #
  # Common patterns:
  # - "Data shows X, BUT [opinion implying the opposite]" (bait-and-pivot)
  # - "In my 30 years of experience..." (appeal to authority over data)
  # - Attributing cause to an unrelated actor (strawman / false cause)
  # - Presenting a strong claim then immediately undermining it with speculation
  class RhetoricalFallacyAnalyzer
    include LlmHelpers

    Result = Struct.new(
      :fallacies,
      :narrative_bias_score,
      :summary,
      keyword_init: true
    )

    Fallacy = Struct.new(
      :type,
      :severity,
      :excerpt,
      :explanation,
      :undermined_claim,
      keyword_init: true
    )

    # 16 fallacy types informed by classical rhetoric and Schopenhauer's 38 Stratagems
    # ("The Art of Being Right", 1831).
    #
    # Coverage of Schopenhauer's stratagems:
    #   Directly mapped (6): #2→equivocation, #9→twisted_conclusion, #11→false_admission,
    #     #13→paradox_framing, #32→odious_categorization, #37→faulty_proof_exploitation
    #   Covered by existing types (13): #1→loaded_language, #3→source_misrepresentation,
    #     #5→cherry_picking, #6→bait_and_pivot, #8→emotional_manipulation, #12→loaded_language,
    #     #14→headline_bait, #24→false_cause, #25→cherry_picking, #26→strawman,
    #     #29→bait_and_pivot, #30→appeal_to_authority, #38→ad_hominem
    #   Not mapped (19): #4,#7,#10,#15,#16,#17,#18,#19,#20,#21,#22,#23,#27,#28,#33,#34,#35,#36
    #     — these are debate-specific tactics (interruption, question barrage, provocation)
    #     that don't reliably apply to written news analysis without excessive false positives.
    FALLACY_TYPES = %w[
      bait_and_pivot
      appeal_to_authority
      false_cause
      strawman
      anecdote_over_data
      loaded_language
      false_dilemma
      slippery_slope
      ad_hominem
      cherry_picking
      equivocation
      odious_categorization
      twisted_conclusion
      paradox_framing
      false_admission
      faulty_proof_exploitation
    ].freeze

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a rhetorical structure analyst for a fact-checking system. You analyze
      how an article's writing structure relates to its factual claims.

      Your job is to detect logical fallacies and rhetorical manipulation — specifically
      when an article presents factual data but then uses rhetorical devices to undermine,
      reframe, or redirect the reader toward a narrative not supported by the evidence.

      For each fallacy detected, provide:
      - type: one of #{FALLACY_TYPES.join(', ')}
      - severity: low, medium, or high
      - excerpt: the exact passage from the article (quote it verbatim, max 200 chars)
      - explanation: why this is a fallacy and what narrative it pushes
      - undermined_claim_index: which claim (by index) it undermines, or null

      Fallacy definitions for this context:

      bait_and_pivot: Article states a fact (often with data) then immediately pivots with
      "but", "however", "yet" to an opinion or implication that contradicts or undermines
      the fact. Example: "Crime fell 5% this quarter, but the president still condones violence."

      appeal_to_authority: Invoking personal experience, credentials, or unnamed experts to
      override data. Example: "The Fed says inflation is down, but in my 30 years in finance,
      I know it will bounce back."

      false_cause: Attributing a causal relationship without evidence. Example: "Unemployment
      dropped, despite the government's disastrous policies" (implying the policies should
      have caused unemployment to rise).

      strawman: Misrepresenting a position to make it easier to attack. Example: "Supporters
      of the new law want to destroy small business" when the law is about tax brackets.

      anecdote_over_data: Using a single story or case to override statistical evidence.
      Example: "GDP grew 3%, but I talked to Maria who lost her job."

      loaded_language: Using emotionally charged words to bias the reader beyond what the
      facts support. Example: "The regime's GDP figures" instead of "government GDP data."

      false_dilemma: Presenting only two options when more exist. Example: "Either we accept
      these inflation numbers or admit the economy is in freefall."

      slippery_slope: Arguing that one event will inevitably lead to extreme consequences
      without evidence. Example: "If rates drop now, hyperinflation is guaranteed."

      ad_hominem: Attacking the source of data rather than the data itself. Example: "These
      numbers come from the same agency that got it wrong in 2008."

      cherry_picking: Selectively presenting data that supports a narrative while ignoring
      contradicting data that the article itself mentions.

      equivocation: Using the same term with different meanings in different parts of the
      article to create a false impression of consistency. Example: "growth" meaning GDP
      growth in one paragraph and stock market growth in another, implying both support
      the same conclusion. (Based on Schopenhauer's Stratagem #2)

      odious_categorization: Dismissing a position or group by assigning a negative label
      rather than engaging with the substance. Example: labeling opposition as
      "ultraconservative", "extremist", "denialist", or "radical" without addressing their
      actual arguments. This is distinct from ad_hominem — it targets a group or position
      rather than an individual. (Based on Schopenhauer's Stratagem #32)

      twisted_conclusion: The article's data or evidence points toward conclusion X, but
      the article draws conclusion Y instead, without justifying the leap. The facts are
      reported accurately but the editorial conclusion doesn't follow from them.
      (Based on Schopenhauer's Stratagem #9)

      paradox_framing: Framing a claim so that rejecting it appears absurd, irrational,
      or morally indefensible — even when legitimate counter-arguments exist. Example:
      "Anyone who questions this policy must want people to suffer." Forces the reader
      into agreement by making dissent socially costly rather than logically unsound.
      (Based on Schopenhauer's Stratagem #13)

      false_admission: Treating an unproven or alleged claim as established fact later
      in the same article. The article initially presents something as alleged, reported,
      or unverified, but subsequent paragraphs refer to it as though it were confirmed.
      Example: "Sources say X happened" in paragraph 2, then "Since X happened, the
      consequences are..." in paragraph 8 — the allegation silently became a fact.
      (Based on Schopenhauer's Stratagem #11)

      faulty_proof_exploitation: Attacking a weak or flawed argument to dismiss an
      entire position, even when stronger arguments for that position exist. The article
      finds one bad piece of evidence and uses it to discredit the whole case, ignoring
      other valid evidence. Example: "The study cited by critics was retracted, therefore
      the concern is baseless" — when other unrebutted evidence supports the concern.
      (Based on Schopenhauer's Stratagem #37)

      IMPORTANT rules:
      - Only flag clear, identifiable fallacies. Do NOT flag normal journalistic framing,
        legitimate expert analysis, or balanced reporting.
      - A journalist providing context is NOT a fallacy. A journalist contradicting their
        own article's data with opinion IS a fallacy.
      - Rate severity based on how much the fallacy undermines the factual claims:
        - high: directly contradicts a high-confidence claim to push a false narrative
        - medium: subtly reframes factual data through rhetorical devices
        - low: mild framing bias that doesn't fundamentally mislead
      - The narrative_bias_score (0.0-1.0) reflects overall rhetorical manipulation:
        0.0 = straight factual reporting, 1.0 = entirely rhetorical manipulation.
      - Return empty fallacies array if the article is straightforward reporting.

      IMPORTANT: The type and severity fields must always use the English enum values above.
      However, write the explanation, summary, and excerpt texts in %{locale_name}.


      CRITICAL — NO HALLUCINATION: Only reference URLs, sources, claims, quotes, and data
      that are EXPLICITLY present in the input provided to you. Do not invent, guess, or
      fabricate any URL, source name, statistic, quote, or claim. If you cannot verify
      something from the provided text, mark it as "unverifiable" — never fill in details
      you are unsure about. Every excerpt must be traceable to the provided input.

      Return strict JSON matching the schema.
    PROMPT

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      article = @investigation.root_article
      return empty_result unless article&.body_text.present?
      return empty_result unless assessed_claims.any?

      llm_result = run_llm_analysis(article)
      return heuristic_analysis(article) unless llm_result

      llm_result
    end

    private

    def assessed_claims
      @assessed_claims ||= @investigation.claim_assessments
        .includes(:claim)
        .where.not(verdict: "pending")
        .order(confidence_score: :desc)
    end

    def run_llm_analysis(article)
      return nil unless llm_available?

      prompt = build_prompt(article)
      fingerprint = Digest::SHA256.hexdigest(prompt)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return parse_response(cached.response_json)
      end

      interaction = create_interaction(model, prompt, fingerprint)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        llm_chat(model:)
          .with_instructions(system_prompt)
          .with_schema(response_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_response(payload)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Rhetorical analysis LLM failed: #{e.message}")
      nil
    end

    def build_prompt(article)
      claims_context = assessed_claims.map.with_index do |assessment, i|
        {
          index: i,
          claim: assessment.claim.canonical_text,
          verdict: assessment.verdict,
          confidence: assessment.confidence_score.to_f,
          authority_score: assessment.authority_score.to_f,
          has_primary_evidence: assessment.evidence_items.any? { |e| e.article&.authority_tier == "primary" }
        }
      end

      # Include upstream analyzer results for cross-analysis
      upstream = {}
      if (sm = @investigation.source_misrepresentation).present?
        upstream[:source_misrepresentation_score] = sm["misrepresentation_score"].to_f
        upstream[:distorted_sources] = Array(sm["misrepresentations"]).count { |m| m["verdict"].in?(%w[distorted fabricated]) }
      end
      if (tm = @investigation.temporal_manipulation).present?
        upstream[:temporal_integrity_score] = tm["temporal_integrity_score"].to_f
        upstream[:temporal_issues] = Array(tm["manipulations"]).size
      end
      if (sd = @investigation.statistical_deception).present?
        upstream[:statistical_integrity_score] = sd["statistical_integrity_score"].to_f
        upstream[:statistical_issues] = Array(sd["deceptions"]).size
      end
      if (sq = @investigation.selective_quotation).present?
        upstream[:quotation_integrity_score] = sq["quotation_integrity_score"].to_f
        upstream[:problematic_quotes] = Array(sq["quotations"]).count { |q| q["verdict"].in?(%w[truncated reversed fabricated]) }
      end

      {
        article_title: article.title,
        article_body: article.body_text.to_s.truncate(4000),
        article_source_kind: article.source_kind,
        assessed_claims: claims_context,
        upstream_analysis: upstream.presence
      }.compact.to_json
    end

    def response_schema
      {
        name: "rhetorical_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            fallacies: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  type: { type: "string", enum: FALLACY_TYPES },
                  severity: { type: "string", enum: %w[low medium high] },
                  excerpt: { type: "string" },
                  explanation: { type: "string" },
                  undermined_claim_index: { type: "integer", description: "Index of the undermined claim, or -1 if none" }
                },
                required: %w[type severity excerpt explanation undermined_claim_index]
              }
            },
            narrative_bias_score: { type: "number" },
            summary: { type: "string" }
          },
          required: %w[fallacies narrative_bias_score summary]
        }
      }
    end

    def parse_response(payload)
      fallacies = Array(payload["fallacies"]).map do |f|
        undermined = if f["undermined_claim_index"].is_a?(Integer) && f["undermined_claim_index"] >= 0 && assessed_claims[f["undermined_claim_index"]]
          assessed_claims[f["undermined_claim_index"]].claim.canonical_text
        end

        Fallacy.new(
          type: f["type"],
          severity: f["severity"],
          excerpt: f["excerpt"],
          explanation: f["explanation"],
          undermined_claim: undermined
        )
      end

      Result.new(
        fallacies: fallacies,
        narrative_bias_score: payload["narrative_bias_score"].to_f.clamp(0, 1).round(2),
        summary: payload["summary"].to_s
      )
    end

    # ── Heuristic fallback when LLM is unavailable ──

    PIVOT_PATTERNS = [
      /\b(data|statistics?|numbers?|figures?|report)\b.{0,80}\b(but|however|yet|nevertheless|despite|still)\b/im,
      /\b(fell|dropped|grew|increased|rose|declined|improved)\b.{0,80}\b(but|however|yet|still)\b/im,
      /\b(dados|estatísticas?|números|relatório)\b.{0,80}\b(mas|porém|contudo|entretanto|apesar)\b/im
    ].freeze

    AUTHORITY_APPEAL_PATTERNS = [
      /\bin my (\d+\s+)?years?\b/i,
      /\bas (a|an) (expert|economist|analyst|journalist|professor)\b/i,
      /\bin my (long\s+)?(career|experience)\b/i,
      /\bna minha (longa\s+)?(carreira|experiência)\b/i,
      /\bcomo (economista|analista|especialista|professor)\b/i
    ].freeze

    # Schopenhauer #32: Odious categorization — dismissive labels used to discredit
    ODIOUS_LABEL_PATTERNS = [
      /\b(ultra)?conservador[a]?\b/i,
      /\bextremist[a]?\b/i,
      /\bnegacionista\b/i,
      /\bradical\b/i,
      /\bfanátic[oa]\b/i,
      /\bextrem(e|ist)\b/i,
      /\bdenialist\b/i,
      /\bfanatic\b/i,
      /\bfar[- ]?(right|left)\b/i,
      /\bextrema[- ]?(direita|esquerda)\b/i
    ].freeze

    # Schopenhauer #13: Paradox framing — making dissent seem absurd
    PARADOX_FRAMING_PATTERNS = [
      /\bquem\s+(é\s+)?contra\b.{0,40}\b(quer|deseja|prefere)\b/i,
      /\bqualquer\s+pessoa\s+(sensata|racional|decente)\b/i,
      /\banyone\s+who\s+(opposes?|questions?|rejects?)\b.{0,40}\b(wants?|must)\b/i,
      /\bno\s+reasonable\s+person\b/i,
      /\bonly\s+a\s+(fool|idiot)\b/i
    ].freeze

    def heuristic_analysis(article)
      body = article.body_text.to_s
      fallacies = []

      # Detect bait-and-pivot
      PIVOT_PATTERNS.each do |pattern|
        match = body.match(pattern)
        if match
          fallacies << Fallacy.new(
            type: "bait_and_pivot",
            severity: "medium",
            excerpt: match[0].truncate(200),
            explanation: I18n.t("heuristic_fallbacks.bait_and_pivot_explanation")
          )
          break
        end
      end

      # Detect appeal to authority
      AUTHORITY_APPEAL_PATTERNS.each do |pattern|
        match = body.match(pattern)
        if match
          fallacies << Fallacy.new(
            type: "appeal_to_authority",
            severity: "low",
            excerpt: match[0].truncate(200),
            explanation: I18n.t("heuristic_fallbacks.appeal_to_authority_explanation")
          )
          break
        end
      end

      # Detect odious categorization (Schopenhauer #32)
      ODIOUS_LABEL_PATTERNS.each do |pattern|
        match = body.match(pattern)
        if match
          fallacies << Fallacy.new(
            type: "odious_categorization",
            severity: "low",
            excerpt: match[0].truncate(200),
            explanation: I18n.t("heuristic_fallbacks.odious_categorization_explanation")
          )
          break
        end
      end

      # Detect paradox framing (Schopenhauer #13)
      PARADOX_FRAMING_PATTERNS.each do |pattern|
        match = body.match(pattern)
        if match
          fallacies << Fallacy.new(
            type: "paradox_framing",
            severity: "medium",
            excerpt: match[0].truncate(200),
            explanation: I18n.t("heuristic_fallbacks.paradox_framing_explanation")
          )
          break
        end
      end

      bias_score = [ fallacies.size * 0.2, 0.6 ].min

      Result.new(
        fallacies: fallacies,
        narrative_bias_score: bias_score.round(2),
        summary: fallacies.any? ? I18n.t("heuristic_fallbacks.heuristic_summary", count: fallacies.size) : I18n.t("heuristic_fallbacks.no_issues")
      )
    end

    def empty_result
      Result.new(fallacies: [], narrative_bias_score: 0.0, summary: I18n.t("heuristic_fallbacks.no_analysis"))
    end

    def interaction_type_name
      :rhetorical_analysis
    end

    def system_prompt
      # Use gsub instead of % formatting because the template contains literal
      # percent signs in examples (e.g. "5% this quarter") that break Ruby's % operator
      SYSTEM_PROMPT_TEMPLATE.gsub("%{locale_name}", locale_name)
    end
  end
end
