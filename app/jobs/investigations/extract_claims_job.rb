module Investigations
  class ExtractClaimsJob < ApplicationJob
    queue_as :default

    def perform(investigation_id)
      @investigation = Investigation.includes(:root_article).find(investigation_id)

      result = Pipeline::StepRunner.call(investigation: @investigation, name: "extract_claims") do
        article = @investigation.root_article || raise("Investigation is missing a root article")
        Articles::SyncClaims.call(investigation: @investigation, article:)

        { claims_count: @investigation.claim_assessments.count }
      end
      @step_succeeded = result.executed
    ensure
      if @investigation
        Investigations::AssessClaimsJob.perform_later(@investigation.id) if @step_succeeded
        if @step_succeeded && @investigation.investigation_group_id && @investigation.group_membership_kind_manual?
          ReconcileGroupEvidenceJob.perform_later(@investigation.id)
        end
        Investigations::RefreshStatus.call(@investigation)
      end
    end
  end
end
