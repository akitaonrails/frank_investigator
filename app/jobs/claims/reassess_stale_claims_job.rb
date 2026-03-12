module Claims
  class ReassessStaleClaimsJob < ApplicationJob
    queue_as :default

    MAX_REASSESSMENTS_PER_RUN = 20

    def perform
      stale_assessments = ClaimAssessment
        .where.not(stale_at: nil)
        .includes(:claim, :investigation)
        .order(stale_at: :asc)
        .limit(MAX_REASSESSMENTS_PER_RUN)

      reassessed = 0

      stale_assessments.each do |assessment|
        reassess!(assessment)
        reassessed += 1
      rescue StandardError => e
        Rails.logger.warn("[ReassessStale] Failed to reassess assessment #{assessment.id}: #{e.message}")
      end

      Rails.logger.info("[ReassessStale] Reassessed #{reassessed} claims")
    end

    private

    def reassess!(assessment)
      result = Analyzers::ClaimAssessor.call(
        investigation: assessment.investigation,
        claim: assessment.claim
      )

      assessment.record_verdict_change!(
        new_verdict: result.verdict,
        new_confidence: result.confidence_score,
        new_reason: result.reason_summary,
        trigger: "reassessment",
        triggered_by: "ReassessStaleClaimsJob(#{assessment.staleness_reason})"
      )

      assessment.update!(
        checkability_status: result.checkability_status,
        missing_evidence_summary: result.missing_evidence_summary,
        conflict_score: result.conflict_score,
        authority_score: result.authority_score,
        independence_score: result.independence_score,
        timeliness_score: result.timeliness_score,
        disagreement_details: result.disagreement_details,
        unanimous: result.unanimous || false,
        assessed_at: Time.current,
        stale_at: nil,
        staleness_reason: nil,
        reassessment_count: assessment.reassessment_count + 1
      )

      # Update evidence article count so we don't re-flag immediately
      assessment.claim.update!(evidence_article_count: assessment.claim.article_claims.count)
    end
  end
end
