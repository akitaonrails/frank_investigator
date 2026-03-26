module Pipeline
  # Resumes investigations interrupted by deploys, crashes, or worker timeouts.
  #
  # Runs on a recurring schedule. For each investigation stuck in "processing":
  # 1. Marks any steps stuck in "running" for >15 min as failed
  # 2. Finds the first required step that isn't completed
  # 3. Enqueues the appropriate job to resume from that point
  #
  # This makes deploys seamless — kamal deploy kills the container mid-pipeline,
  # and the new container picks up where the old one left off within 5 minutes.
  class ResumeInterrupted
    # Maps each required step to the job class that runs it.
    # Steps handled by BatchContentAnalysisJob are mapped to it since
    # it creates all 5 sub-steps in one go.
    STEP_TO_JOB = {
      "fetch_root_article" => "Investigations::FetchRootArticleJob",
      "extract_claims" => "Investigations::ExtractClaimsJob",
      "analyze_headline" => "Investigations::AnalyzeHeadlineJob",
      "assess_claims" => "Investigations::AssessClaimsJob",
      "expand_linked_articles_root" => nil, # triggered by fetch_root_article
      "detect_source_misrepresentation" => "Investigations::BatchContentAnalysisJob",
      "detect_temporal_manipulation" => "Investigations::BatchContentAnalysisJob",
      "detect_statistical_deception" => "Investigations::BatchContentAnalysisJob",
      "detect_selective_quotation" => "Investigations::BatchContentAnalysisJob",
      "detect_authority_laundering" => "Investigations::BatchContentAnalysisJob",
      "analyze_rhetorical_structure" => "Investigations::AnalyzeRhetoricalStructureJob",
      "analyze_contextual_gaps" => "Investigations::AnalyzeContextualGapsJob",
      "detect_coordinated_narrative" => "Investigations::DetectCoordinatedNarrativeJob",
      "score_emotional_manipulation" => "Investigations::ScoreEmotionalManipulationJob",
      "generate_summary" => "Investigations::GenerateSummaryJob"
    }.freeze

    def self.call
      new.call
    end

    def call
      recover_stale_steps!
      resume_interrupted_investigations!
    end

    private

    def recover_stale_steps!
      PipelineStep.where(status: "running").where("started_at < ?", 15.minutes.ago).find_each do |step|
        step.update!(status: :failed, error_message: "Recovered: step exceeded 15 minute timeout", finished_at: Time.current)
        Rails.logger.warn("[PipelineResume] Marked stale step #{step.name} as failed on investigation #{step.investigation_id}")
      end
    end

    def resume_interrupted_investigations!
      Investigation.where(status: %w[processing queued]).find_each do |inv|
        # Skip if any steps are currently running (not stale)
        next if inv.pipeline_steps.where(status: "running").exists?

        first_incomplete = find_first_incomplete_step(inv)
        next unless first_incomplete

        job_class = resolve_job(first_incomplete)
        next unless job_class

        # Don't double-enqueue — check if a job for this investigation is already queued
        next if job_already_queued?(inv, job_class)

        Rails.logger.info("[PipelineResume] Resuming investigation #{inv.id} (#{inv.slug}) from step #{first_incomplete}")
        job_class.constantize.perform_later(inv.id)
      end
    end

    def find_first_incomplete_step(investigation)
      step_map = investigation.pipeline_steps.index_by(&:name)

      Investigation::REQUIRED_STEPS.each do |name|
        step = step_map[name]
        return name unless step&.completed?
      end

      # All steps completed but status is still processing — just refresh
      Investigations::RefreshStatus.call(investigation)
      nil
    end

    def resolve_job(step_name)
      job = STEP_TO_JOB[step_name]
      return nil unless job

      # For batch steps, only trigger once (when the first batch step is incomplete)
      if job == "Investigations::BatchContentAnalysisJob"
        # All 5 batch steps map here, but we only want to trigger once
        return job
      end

      job
    end

    def job_already_queued?(investigation, job_class_name)
      SolidQueue::Job.where(class_name: job_class_name)
        .where("arguments LIKE ?", "%#{investigation.id}%")
        .where(finished_at: nil)
        .exists?
    rescue StandardError
      false
    end
  end
end
