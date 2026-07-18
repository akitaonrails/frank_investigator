module Investigations
  class KickoffJob < ApplicationJob
    queue_as :default

    def perform(investigation_id, delivery_token = nil)
      @investigation = Investigation.find(investigation_id)

      result = Pipeline::StepRunner.call(investigation: @investigation, name: "kickoff") do
        @investigation.update!(status: :processing)
        {}
      end
      @step_succeeded = result.executed || @investigation.pipeline_steps.exists?(name: "kickoff", status: "completed")
      if @step_succeeded && (result.executed || delivery_token.present?)
        # Keep the delivery fence until the root-fetch handoff has been accepted
        # by the adapter. A recovery may safely repeat this idempotent job.
        Investigations::FetchRootArticleJob.perform_later(@investigation.id, delivery_token)
      end
    ensure
      if @investigation
        Investigations::RefreshStatus.call(@investigation)
      end
    end
  end
end
