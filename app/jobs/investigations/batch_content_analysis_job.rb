module Investigations
  # Replaces 5 sequential LLM calls with a single batched call.
  # Runs: source misrepresentation, temporal manipulation, statistical deception,
  # selective quotation, and authority laundering in one LLM request.
  class BatchContentAnalysisJob < ApplicationJob
    queue_as :default

    STEP_COLUMNS = {
      "detect_source_misrepresentation" => :source_misrepresentation,
      "detect_temporal_manipulation" => :temporal_manipulation,
      "detect_statistical_deception" => :statistical_deception,
      "detect_selective_quotation" => :selective_quotation,
      "detect_authority_laundering" => :authority_laundering
    }.freeze

    def perform(investigation_id)
      @investigation = Investigation.includes(:root_article, claim_assessments: :claim).find(investigation_id)

      # Run the batch analyzer (single LLM call)
      results = Analyzers::BatchContentAnalyzer.call(investigation: @investigation)

      # Store each result and create pipeline steps
      STEP_COLUMNS.each do |step_name, column|
        Pipeline::StepRunner.call(investigation: @investigation, name: step_name, allow_rerun: true) do
          data = results[column]
          @investigation.update_column(column, data) if data
          { batched: true }
        end
      end
      @step_succeeded = true
    ensure
      if @investigation && @step_succeeded
        # Fan out: these 3 steps are independent and run in parallel
        Investigations::AnalyzeRhetoricalStructureJob.perform_later(@investigation.id)
        Investigations::AnalyzeContextualGapsJob.perform_later(@investigation.id)
        Investigations::DetectCoordinatedNarrativeJob.perform_later(@investigation.id)
      end
      Investigations::RefreshStatus.call(@investigation) if @investigation
    end
  end
end
