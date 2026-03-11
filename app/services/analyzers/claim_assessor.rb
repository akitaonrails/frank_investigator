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

      entries = evidence_entries
      weighted_support = weight_for(entries, :supports)
      weighted_dispute = weight_for(entries, :disputes)
      authority_score = normalized_authority_score(entries)
      independence_score = normalized_independence_score(entries)
      timeliness_score = normalized_timeliness_score(entries)
      sufficiency_score = normalized_sufficiency_score(entries)
      heuristic_verdict = verdict_for(weighted_support:, weighted_dispute:, sufficiency_score:)
      heuristic_confidence = confidence_for(
        sufficiency_score:,
        authority_score:,
        independence_score:,
        timeliness_score:,
        weighted_support:,
        weighted_dispute:
      )
      llm_result = llm_client.call(claim: @claim, evidence_packet: structured_evidence_packet(entries), investigation: @investigation) if llm_client_available? && entries.any?
      final_verdict, final_confidence = merge_with_llm(heuristic_verdict:, heuristic_confidence:, llm_result:)

      Result.new(
        verdict: final_verdict,
        confidence_score: final_confidence.round(2),
        checkability_status: :checkable,
        reason_summary: llm_result&.reason_summary || reason_summary_for(entries, heuristic_verdict, weighted_support, weighted_dispute),
        missing_evidence_summary: missing_evidence_summary_for(entries, sufficiency_score),
        conflict_score: conflict_score_for(weighted_support, weighted_dispute),
        authority_score: authority_score.round(2),
        independence_score: independence_score.round(2),
        timeliness_score: timeliness_score.round(2)
      )
    end

    private

    def evidence_entries
      @evidence_entries ||= EvidencePacketBuilder.call(investigation: @investigation, claim: @claim)
    end

    def structured_evidence_packet(entries)
      entries.map do |entry|
        {
          url: entry.article.normalized_url,
          title: entry.article.title,
          excerpt: entry.article.excerpt,
          stance: entry.stance,
          relevance_score: entry.relevance_score,
          authority_score: entry.authority_score,
          authority_tier: entry.authority_tier,
          source_kind: entry.source_kind,
          independence_group: entry.independence_group,
          fetched_at: entry.article.fetched_at
        }
      end
    end

    def weight_for(entries, stance)
      entries.select { |entry| entry.stance == stance }.sum do |entry|
        entry.relevance_score.to_f * entry.authority_score.to_f
      end
    end

    def normalized_authority_score(entries)
      return 0.05 if entries.empty?

      [entries.sum { |entry| entry.authority_score.to_f * entry.relevance_score.to_f }, 1.0].min
    end

    def normalized_independence_score(entries)
      groups = entries.map(&:independence_group).reject(&:blank?).uniq.count
      return 0.05 if groups.zero?

      [groups * 0.28, 1.0].min
    end

    def normalized_timeliness_score(entries)
      dated_entries = entries.count { |entry| entry.article.fetched_at.present? }
      return 0.1 if dated_entries.zero?

      [0.25 + (dated_entries * 0.15), 1.0].min
    end

    def normalized_sufficiency_score(entries)
      return 0 if entries.empty?

      primary_entries = entries.count { |entry| entry.authority_tier == "primary" }
      weighted_count = entries.sum { |entry| entry.relevance_score.to_f }
      [(weighted_count * 0.25) + (primary_entries * 0.2), 1.0].min
    end

    def verdict_for(weighted_support:, weighted_dispute:, sufficiency_score:)
      return :needs_more_evidence if sufficiency_score < 0.35
      return :mixed if weighted_support >= 0.55 && weighted_dispute >= 0.55
      return :supported if weighted_support >= [weighted_dispute * 1.35, 0.7].max
      return :disputed if weighted_dispute >= [weighted_support * 1.35, 0.7].max

      :needs_more_evidence
    end

    def confidence_for(sufficiency_score:, authority_score:, independence_score:, timeliness_score:, weighted_support:, weighted_dispute:)
      conflict_penalty = conflict_score_for(weighted_support, weighted_dispute)
      ((sufficiency_score * 0.35) + (authority_score * 0.25) + (independence_score * 0.2) + (timeliness_score * 0.2) - (conflict_penalty * 0.25)).clamp(0, 0.97)
    end

    def conflict_score_for(weighted_support, weighted_dispute)
      return 0.05 if weighted_support.zero? || weighted_dispute.zero?

      [[weighted_support, weighted_dispute].min / [weighted_support, weighted_dispute].max, 1.0].min
    end

    def merge_with_llm(heuristic_verdict:, heuristic_confidence:, llm_result:)
      return [heuristic_verdict, heuristic_confidence] unless llm_result

      llm_verdict = llm_result.verdict.to_sym
      return [heuristic_verdict, [heuristic_confidence + 0.05, 0.99].min] if llm_verdict == heuristic_verdict
      return [llm_verdict, llm_result.confidence_score.to_f.clamp(0, 0.99)] if heuristic_verdict == :needs_more_evidence && llm_result.confidence_score.to_f >= 0.8

      [ :mixed, [heuristic_confidence - 0.12, 0.1].max ]
    end

    def reason_summary_for(entries, heuristic_verdict, weighted_support, weighted_dispute)
      return "No linked evidence was relevant enough to assess this claim yet." if entries.empty?

      primary_count = entries.count { |entry| entry.authority_tier == "primary" }
      independent_groups = entries.map(&:independence_group).uniq.count

      "Weighted evidence points to #{heuristic_verdict.to_s.humanize.downcase}. " \
        "#{primary_count} primary-source items and #{independent_groups} independent source groups were relevant. " \
        "Support weight #{weighted_support.round(2)}, dispute weight #{weighted_dispute.round(2)}."
    end

    def missing_evidence_summary_for(entries, sufficiency_score)
      return "Need at least one relevant linked source before the claim can be assessed." if entries.empty?
      return "Need more independent or primary-source evidence before reaching a firm conclusion." if sufficiency_score < 0.55

      "Evidence exists, but more contradiction checks across independent sources would improve confidence."
    end

    def llm_client
      @llm_client ||= Llm::ClientFactory.build
    end

    def llm_client_available?
      llm_client.respond_to?(:available?) ? llm_client.available? : true
    end
  end
end
