module Investigations
  class AssessClaimsJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:claim_assessments, :root_article).find(investigation_id)

      Pipeline::StepRunner.call(investigation: @investigation, name: "assess_claims", allow_rerun: true) do
        run_authority_retrieval!
        run_active_evidence_retrieval!

        assessments = @investigation.claim_assessments.includes(:claim).to_a
        checkable = assessments.select { |a| a.claim.checkable? || a.claim.pending? }

        # Pre-compute evidence packets and heuristic scores for all checkable claims
        claim_data = checkable.filter_map do |assessment|
          entries = Analyzers::EvidencePacketBuilder.call(investigation: @investigation, claim: assessment.claim)
          assessor = Analyzers::ClaimAssessor.new(investigation: @investigation, claim: assessment.claim)
          { assessment:, entries:, assessor: }
        end

        # Batch LLM assessment: send all claims with evidence in grouped calls
        llm_results = run_batch_llm_assessment(claim_data)

        ApplicationRecord.transaction do
          claim_data.each do |data|
            assessment = data[:assessment]
            llm_result = llm_results[assessment.claim.id]
            result = data[:assessor].call_with_llm_result(data[:entries], llm_result)

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
              citation_depth_score: result.citation_depth_score || 1.0,
              primary_vetoed: result.primary_vetoed || false,
              unsubstantiated_viral: result.unsubstantiated_viral || false,
              assessed_at: Time.current
            )

            assessment.claim.update!(evidence_article_count: assessment.claim.article_claims.count)
            sync_evidence_items!(assessment)
          end

          # Handle non-checkable claims
          (assessments - checkable).each do |assessment|
            next unless assessment.claim.not_checkable?
            result = Analyzers::ClaimAssessor.call(investigation: @investigation, claim: assessment.claim)
            assessment.record_verdict_change!(
              new_verdict: result.verdict,
              new_confidence: result.confidence_score,
              new_reason: result.reason_summary,
              trigger: "initial_assessment",
              triggered_by: self.class.name
            )
            assessment.update!(checkability_status: result.checkability_status, assessed_at: Time.current)
          end
        end

        Investigations::BatchContentAnalysisJob.perform_later(@investigation.id)

        { assessed_claims_count: @investigation.claim_assessments.count }
      end
    ensure
      Investigations::RefreshStatus.call(@investigation) if @investigation
    end

    private

    def run_batch_llm_assessment(claim_data)
      client = Llm::ClientFactory.build
      return {} unless client.respond_to?(:call_batch) && client.respond_to?(:available?) && client.available?

      items_with_evidence = claim_data.filter_map do |data|
        next if data[:entries].empty?
        {
          claim: data[:assessment].claim,
          evidence_packet: data[:assessor].structured_evidence_packet(data[:entries])
        }
      end

      return {} if items_with_evidence.empty?

      client.call_batch(items: items_with_evidence, investigation: @investigation)
    rescue StandardError => e
      Rails.logger.warn("[AssessClaimsJob] Batch LLM assessment failed, falling back to individual: #{e.message}")
      {}
    end

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

    MAX_SEARCH_FETCHES_PER_INVESTIGATION = 8

    def run_active_evidence_retrieval!
      total_fetched = 0

      @investigation.claim_assessments.includes(:claim).find_each do |assessment|
        break if total_fetched >= MAX_SEARCH_FETCHES_PER_INVESTIGATION
        next unless assessment.claim.checkable?

        existing = Analyzers::EvidencePacketBuilder.call(investigation: @investigation, claim: assessment.claim)
        independent_groups = existing.map(&:independence_group).uniq.count
        next if independent_groups >= 3

        results = Analyzers::ActiveEvidenceRetriever.call(
          investigation: @investigation,
          claim: assessment.claim
        )
        total_fetched += results.size
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
