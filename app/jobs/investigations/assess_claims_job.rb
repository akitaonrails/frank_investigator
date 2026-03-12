module Investigations
  class AssessClaimsJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:claim_assessments, :root_article).find(investigation_id)

      Pipeline::StepRunner.call(investigation: @investigation, name: "assess_claims", allow_rerun: true) do
        run_authority_retrieval!
        run_active_evidence_retrieval!

        ApplicationRecord.transaction do
          @investigation.claim_assessments.includes(:claim).find_each do |assessment|
            result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: assessment.claim)

            is_initial = assessment.verdict_pending?
            assessment.record_verdict_change!(
              new_verdict: result.verdict,
              new_confidence: result.confidence_score,
              new_reason: result.reason_summary,
              trigger: is_initial ? "initial_assessment" : "reassessment",
              triggered_by: self.class.name
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
              assessed_at: Time.current
            )

            assessment.claim.update!(evidence_article_count: assessment.claim.article_claims.count)
            sync_evidence_items!(assessment)
          end
        end

        AnalyzeRhetoricalStructureJob.perform_later(@investigation.id)

        { assessed_claims_count: @investigation.claim_assessments.count }
      end
    ensure
      Investigations::RefreshStatus.call(@investigation) if @investigation
    end

    private

    def run_authority_retrieval!
      @investigation.claim_assessments.includes(:claim).find_each do |assessment|
        next unless assessment.claim.checkable? || assessment.claim.pending?

        Analyzers::AuthorityRetrievalDispatcher.call(
          investigation: @investigation,
          claim: assessment.claim
        )
      end
    rescue StandardError => e
      Rails.logger.warn("Authority retrieval failed: #{e.message}")
    end

    def run_active_evidence_retrieval!
      @investigation.claim_assessments.includes(:claim).find_each do |assessment|
        next unless assessment.claim.checkable?

        # Skip if we already have good evidence
        existing = Analyzers::EvidencePacketBuilder.call(investigation: @investigation, claim: assessment.claim)
        primary_count = existing.count { |e| e.authority_tier == "primary" }
        next if primary_count >= 2

        Analyzers::ActiveEvidenceRetriever.call(
          investigation: @investigation,
          claim: assessment.claim
        )
      end
    rescue StandardError => e
      Rails.logger.warn("Active evidence retrieval failed: #{e.message}")
    end

    def sync_evidence_items!(assessment)
      existing_urls = []

      Analyzers::EvidencePacketBuilder.call(investigation: @investigation, claim: assessment.claim).each do |entry|
        article = entry.article
        existing_urls << article.normalized_url

        item = EvidenceItem.find_or_initialize_by(claim_assessment: assessment, source_url: article.normalized_url)
        item.article = article
        item.source_type = article.evidence_source_type
        item.source_kind = article.source_kind
        item.stance = entry.stance
        item.relevance_score = entry.relevance_score
        item.published_at = article.published_at
        item.excerpt = article.excerpt
        item.citation_locator = article.main_content_path
        item.authority_score = article.authority_score
        item.independence_group = article.independence_group.presence || article.host
        item.save!
      end

      assessment.evidence_items.where.not(source_url: existing_urls).destroy_all
    end
  end
end
