module Analyzers
  class ClaimAssessor
    Result = Struct.new(
      :verdict,
      :confidence_score,
      :checkability_status,
      :reason_summary,
      :missing_evidence_summary,
      :conflict_score,
      :authority_score,
      :independence_score,
      :timeliness_score,
      :disagreement_details,
      :unanimous,
      keyword_init: true
    )

    def self.call(investigation:, claim:)
      new(investigation:, claim:).call
    end

    def initialize(investigation:, claim:)
      @investigation = investigation
      @claim = claim
    end

    def call
      if @claim.not_checkable?
        return Result.new(
          verdict: :not_checkable,
          confidence_score: 0.9,
          checkability_status: :not_checkable,
          reason_summary: "This statement reads as opinion, rhetoric, or framing rather than a verifiable factual claim.",
          missing_evidence_summary: "No public evidence set can conclusively verify a subjective statement.",
          conflict_score: 0,
          authority_score: 0,
          independence_score: 0,
          timeliness_score: 0
        )
      end

      # Check for prior assessments of this claim in other investigations
      prior = find_prior_assessment
      return prior if prior

      entries = evidence_entries
      scores = compute_scores(entries)
      heuristic_verdict = verdict_for(**scores)
      heuristic_confidence = confidence_for(**scores)
      llm_result = run_llm_assessment(entries)
      final_verdict, final_confidence = merge_with_llm(heuristic_verdict:, heuristic_confidence:, llm_result:)
      final_verdict, final_confidence = apply_primary_veto(final_verdict, final_confidence, entries)

      Result.new(
        verdict: final_verdict,
        confidence_score: final_confidence.round(2),
        checkability_status: :checkable,
        reason_summary: build_reason_summary(entries, final_verdict, scores, llm_result),
        missing_evidence_summary: build_missing_evidence(entries, scores[:sufficiency_score]),
        conflict_score: scores[:conflict_score].round(2),
        authority_score: scores[:authority_score].round(2),
        independence_score: scores[:independence_score].round(2),
        timeliness_score: scores[:timeliness_score].round(2),
        disagreement_details: llm_result&.disagreement_details,
        unanimous: llm_result&.unanimous
      )
    end

    private

    def find_prior_assessment
      # Exact claim match in other investigations
      prior = ClaimAssessment
        .where(claim: @claim)
        .where.not(investigation: @investigation)
        .where.not(verdict: "pending")
        .order(confidence_score: :desc)
        .first

      # Similarity-based match against claims from completed investigations
      prior ||= find_similar_prior_assessment

      return nil unless prior
      return nil if prior.confidence_score.to_f < 0.4

      similarity_note = prior.claim_id == @claim.id ? "exact match" : "similar claim match"

      Result.new(
        verdict: prior.verdict.to_sym,
        confidence_score: [prior.confidence_score.to_f - 0.05, 0.1].max.round(2),
        checkability_status: prior.checkability_status.to_sym,
        reason_summary: "#{prior.reason_summary} (Reused from a prior investigation — #{similarity_note}.)",
        missing_evidence_summary: prior.missing_evidence_summary,
        conflict_score: prior.conflict_score.to_f,
        authority_score: prior.authority_score.to_f,
        independence_score: prior.independence_score.to_f,
        timeliness_score: prior.timeliness_score.to_f
      )
    end

    SIMILARITY_REUSE_THRESHOLD = 0.65

    def find_similar_prior_assessment
      other_claims = Claim
        .joins(:claim_assessments)
        .where.not(claim_assessments: { verdict: "pending" })
        .where.not(id: @claim.id)
        .distinct

      matches = ClaimSimilarityMatcher.call(
        text: @claim.canonical_text,
        candidates: other_claims
      )

      best = matches.find { |m| m.similarity_score >= SIMILARITY_REUSE_THRESHOLD }
      return nil unless best

      best.claim.claim_assessments
        .where.not(verdict: "pending")
        .order(confidence_score: :desc)
        .first
    end

    def evidence_entries
      @evidence_entries ||= EvidencePacketBuilder.call(investigation: @investigation, claim: @claim)
    end

    def compute_scores(entries)
      weighted_support = weight_for(entries, :supports)
      weighted_dispute = weight_for(entries, :disputes)
      {
        weighted_support:,
        weighted_dispute:,
        authority_score: normalized_authority_score(entries),
        independence_score: normalized_independence_score(entries),
        timeliness_score: normalized_timeliness_score(entries),
        sufficiency_score: normalized_sufficiency_score(entries),
        conflict_score: conflict_score_for(weighted_support, weighted_dispute),
        citation_depth_score: citation_depth_score(entries),
        unsubstantiated_viral: unsubstantiated_viral?(entries)
      }
    end

    def structured_evidence_packet(entries)
      entries.map do |entry|
        {
          url: entry.article.normalized_url,
          title: entry.article.title,
          excerpt: entry.article.excerpt.to_s.truncate(500),
          body_snippet: entry.article.body_text.to_s.truncate(800),
          stance: entry.stance,
          relevance_score: entry.relevance_score,
          authority_score: entry.authority_score,
          authority_tier: entry.authority_tier,
          source_kind: entry.source_kind,
          independence_group: entry.independence_group,
          fetched_at: entry.article.fetched_at,
          published_at: entry.article.published_at,
          headline_divergence: entry.headline_divergence
        }
      end
    end

    # Cap the total contribution of non-primary sources so that sheer volume
    # of secondary/tertiary articles can never outweigh a single primary source.
    # A million articles repeating a falsehood must not drown out one authoritative correction.
    SECONDARY_WEIGHT_CAP = 0.8

    def weight_for(entries, stance)
      stance_entries = entries.select { |entry| entry.stance == stance }

      primary_weight = stance_entries
        .select { |e| e.authority_tier == "primary" }
        .sum { |e| e.relevance_score.to_f * e.authority_score.to_f }

      secondary_weight = stance_entries
        .reject { |e| e.authority_tier == "primary" }
        .sum { |e| e.relevance_score.to_f * e.authority_score.to_f }

      primary_weight + [secondary_weight, SECONDARY_WEIGHT_CAP].min
    end

    def normalized_authority_score(entries)
      return 0.05 if entries.empty?
      [entries.sum { |entry| entry.authority_score.to_f * entry.relevance_score.to_f }, 1.0].min
    end

    def normalized_independence_score(entries)
      groups = entries.map(&:independence_group).reject(&:blank?).uniq.count
      return 0.05 if groups.zero?

      # Run full independence analysis if we have enough articles
      articles = entries.filter_map(&:article).uniq
      if articles.size >= 2
        analysis = IndependenceAnalyzer.call(articles: articles)
        return analysis.independence_score
      end

      [groups * 0.28, 1.0].min
    end

    def normalized_timeliness_score(entries)
      claim_range = claim_time_range
      if claim_range
        scores = entries.map do |entry|
          evidence_date = entry.article.published_at || entry.article.fetched_at
          TemporalScoring.score(evidence_date, claim_range)
        end
        return 0.1 if scores.empty?
        scores.sum / scores.size
      else
        dated_entries = entries.count { |entry| entry.article.fetched_at.present? }
        return 0.1 if dated_entries.zero?
        [0.25 + (dated_entries * 0.15), 1.0].min
      end
    end

    def claim_time_range
      return nil unless @claim.claim_timestamp_start.present? && @claim.claim_timestamp_end.present?
      @claim.claim_timestamp_start..@claim.claim_timestamp_end
    end

    def normalized_sufficiency_score(entries)
      return 0 if entries.empty?
      primary_entries = entries.count { |entry| entry.authority_tier == "primary" }
      weighted_count = entries.sum { |entry| entry.relevance_score.to_f }
      [(weighted_count * 0.25) + (primary_entries * 0.2), 1.0].min
    end

    # If any primary-tier source disputes the claim, cap confidence and force
    # the verdict to at least :mixed — a single authoritative correction
    # outweighs any volume of secondary sources repeating the original claim.
    PRIMARY_VETO_CONFIDENCE_CAP = 0.60

    def apply_primary_veto(verdict, confidence, entries)
      primary_supporting = entries.select { |e| e.authority_tier == "primary" && e.stance == :supports }
      primary_disputing  = entries.select { |e| e.authority_tier == "primary" && e.stance == :disputes }

      # Veto: primary disputes exist but no primary supports
      if primary_disputing.any? && primary_supporting.empty? && verdict == :supported
        return [ :mixed, [confidence, PRIMARY_VETO_CONFIDENCE_CAP].min ]
      end

      # Opposing primaries: force mixed, cap confidence hard
      if primary_disputing.any? && primary_supporting.any?
        return [ :mixed, [confidence, PRIMARY_VETO_CONFIDENCE_CAP - 0.10].min ]
      end

      [ verdict, confidence ]
    end

    # ── Circular citation, headline amplification & unsubstantiated viral detection ──

    def citation_depth_score(entries)
      articles = entries.filter_map(&:article).uniq
      return 1.0 if articles.size < 2

      circular_result = CircularCitationDetector.call(articles: articles)
      headline_result = HeadlineCitationDetector.call(articles: articles)

      # Combine: both circular citations and headline amplification erode evidence quality
      base = circular_result.citation_depth_score
      headline_penalty = headline_result.amplification_score * 0.2
      [base - headline_penalty, 0.0].max.round(2)
    end

    # A claim is "unsubstantiated viral" when many secondary outlets support it
    # but zero primary sources exist. This is the signature of smear campaigns,
    # viral gossip, and cancel mobs: volume without evidence.
    VIRAL_SECONDARY_THRESHOLD = 3

    def unsubstantiated_viral?(entries)
      supporting = entries.select { |e| e.stance == :supports }
      return false if supporting.size < VIRAL_SECONDARY_THRESHOLD

      primary_support = supporting.any? { |e| e.authority_tier == "primary" }
      return false if primary_support

      # All supporting evidence is secondary/low tier — flag as viral
      true
    end

    # Cap for claims where many outlets repeat an unsubstantiated allegation.
    # No amount of secondary-only repetition should produce high confidence.
    UNSUBSTANTIATED_VIRAL_CONFIDENCE_CAP = 0.45

    def verdict_for(weighted_support:, weighted_dispute:, sufficiency_score:, **)
      return :needs_more_evidence if sufficiency_score < 0.35
      return :mixed if weighted_support >= 0.55 && weighted_dispute >= 0.55
      return :supported if weighted_support >= [weighted_dispute * 1.35, 0.7].max
      return :disputed if weighted_dispute >= [weighted_support * 1.35, 0.7].max
      :needs_more_evidence
    end

    SINGLE_CLUSTER_CONFIDENCE_CAP = 0.65

    def confidence_for(sufficiency_score:, authority_score:, independence_score:, timeliness_score:, weighted_support:, weighted_dispute:, citation_depth_score: 1.0, unsubstantiated_viral: false, **)
      conflict_penalty = conflict_score_for(weighted_support, weighted_dispute)

      # Citation depth reduces confidence when evidence articles don't link to
      # substantive external sources (echo chamber / circular citation pattern)
      citation_penalty = [(1.0 - citation_depth_score) * 0.2, 0.2].min

      raw = ((sufficiency_score * 0.30) + (authority_score * 0.25) + (independence_score * 0.20) + (timeliness_score * 0.15) + (citation_depth_score * 0.10) - (conflict_penalty * 0.25) - citation_penalty).clamp(0, 0.97)

      # Cap confidence when independence is very low (single editorial cluster)
      raw = raw.clamp(0, SINGLE_CLUSTER_CONFIDENCE_CAP) if independence_score <= 0.05

      # Hard cap: unsubstantiated viral — many outlets, zero primary evidence
      raw = raw.clamp(0, UNSUBSTANTIATED_VIRAL_CONFIDENCE_CAP) if unsubstantiated_viral

      raw
    end

    def conflict_score_for(weighted_support, weighted_dispute)
      return 0.05 if weighted_support.zero? || weighted_dispute.zero?
      [[weighted_support, weighted_dispute].min / [weighted_support, weighted_dispute].max, 1.0].min
    end

    def run_llm_assessment(entries)
      return nil unless entries.any?
      return nil unless llm_client_available?
      llm_client.call(
        claim: @claim,
        evidence_packet: structured_evidence_packet(entries),
        investigation: @investigation
      )
    end

    def llm_client_available?
      llm_client.respond_to?(:available?) ? llm_client.available? : true
    end

    def merge_with_llm(heuristic_verdict:, heuristic_confidence:, llm_result:)
      return [heuristic_verdict, heuristic_confidence] unless llm_result

      llm_verdict = llm_result.verdict.to_sym
      return [heuristic_verdict, [heuristic_confidence + 0.05, 0.97].min] if llm_verdict == heuristic_verdict
      return [llm_verdict, llm_result.confidence_score.to_f.clamp(0, 0.97)] if heuristic_verdict == :needs_more_evidence && llm_result.confidence_score.to_f >= 0.8
      [ :mixed, [heuristic_confidence - 0.12, 0.1].max ]
    end

    def build_reason_summary(entries, verdict, scores, llm_result)
      # Prefer LLM reason if available and grounded
      if llm_result&.reason_summary.present? && llm_result.reason_summary.length > 20
        return ground_reason_with_citations(llm_result.reason_summary, entries)
      end

      return "No linked evidence was relevant enough to assess this claim yet." if entries.empty?

      primary_sources = entries.select { |e| e.authority_tier == "primary" }
      supporting = entries.select { |e| e.stance == :supports }
      disputing = entries.select { |e| e.stance == :disputes }

      parts = []
      parts << "Verdict: #{verdict.to_s.humanize.downcase}."

      if primary_sources.any?
        cited = primary_sources.first(3).map { |e| "#{e.article.title || e.article.host} (#{e.source_kind.humanize})" }
        parts << "Primary sources: #{cited.join('; ')}."
      end

      if supporting.any?
        parts << "#{supporting.count} source(s) support the claim with combined weight #{scores[:weighted_support].round(2)}."
      end

      if disputing.any?
        parts << "#{disputing.count} source(s) dispute the claim with combined weight #{scores[:weighted_dispute].round(2)}."
      end

      independent_groups = entries.map(&:independence_group).uniq.count
      parts << "Evidence comes from #{independent_groups} independent source group(s)."

      parts.join(" ")
    end

    def ground_reason_with_citations(reason, entries)
      # Append source citations to LLM reasoning
      cited_sources = entries.first(3).map do |entry|
        "[#{entry.article.title || entry.article.host}](#{entry.article.normalized_url})"
      end
      return reason if cited_sources.empty?

      "#{reason} Sources consulted: #{cited_sources.join('; ')}."
    end

    def build_missing_evidence(entries, sufficiency_score)
      return "Need at least one relevant linked source before the claim can be assessed." if entries.empty?

      gaps = []
      primary_count = entries.count { |e| e.authority_tier == "primary" }
      independent_groups = entries.map(&:independence_group).uniq.count

      gaps << "primary authoritative sources" if primary_count.zero?
      gaps << "more independent source groups (currently #{independent_groups})" if independent_groups < 3
      gaps << "dated evidence for temporal verification" if entries.none? { |e| e.article.published_at.present? }

      disputing = entries.count { |e| e.stance == :disputes }
      supporting = entries.count { |e| e.stance == :supports }
      gaps << "contradiction checks (all evidence currently #{supporting > 0 ? 'supports' : 'contextualizes'})" if disputing.zero? && supporting > 0
      gaps << "primary authoritative confirmation (multiple secondary sources repeat the claim but none provide original evidence — possible viral/smear pattern)" if unsubstantiated_viral?(entries) && primary_count.zero?

      baiting_count = entries.count { |e| e.headline_divergence.to_f >= 0.4 }
      gaps << "non-baiting sources (#{baiting_count} source(s) have headlines significantly stronger than their body text — their authority has been discounted)" if baiting_count > 0

      if gaps.any?
        "Still needed: #{gaps.join('; ')}."
      else
        "Evidence base is reasonable. Additional independent confirmation would strengthen confidence."
      end
    end

    def llm_client
      @llm_client ||= Llm::ClientFactory.build
    end
  end
end
