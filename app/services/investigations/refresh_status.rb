module Investigations
  class RefreshStatus
    def self.call(investigation)
      new(investigation).call
    end

    def initialize(investigation)
      @investigation = investigation
    end

    def call
      step_map = @investigation.pipeline_steps.index_by(&:name)

      # Only treat failures in required steps as fatal. Non-required steps
      # (e.g. fetch_linked_article:NNN) can fail without killing the investigation —
      # some external sites will always block us and that's expected.
      required_step_bases = Investigation::REQUIRED_STEPS.to_set
      has_fatal_failure = @investigation.pipeline_steps.failed.any? do |step|
        required_step_bases.include?(step.name)
      end

      status =
        if has_fatal_failure
          :failed
        elsif Investigation::REQUIRED_STEPS.all? { |name| step_map[name]&.completed? }
          :completed
        elsif @investigation.pipeline_steps.running.exists? || @investigation.pipeline_steps.completed.exists?
          :processing
        else
          :queued
        end

      checkability_status =
        if @investigation.claim_assessments.where(checkability_status: "checkable").exists?
          @investigation.claim_assessments.where(checkability_status: "not_checkable").exists? ? :partially_checkable : :checkable
        elsif @investigation.claim_assessments.where(checkability_status: "not_checkable").exists?
          :not_checkable
        else
          :pending
        end

      @investigation.update!(
        status:,
        checkability_status:,
        overall_confidence_score: average_confidence,
        summary: summary_text,
        analysis_completed_at: status == :completed ? (@investigation.analysis_completed_at || Time.current) : nil
      )
    end

    private

    def average_confidence
      scores = @investigation.claim_assessments.pluck(:confidence_score).map(&:to_f)
      return 0 if scores.empty?

      (scores.sum / scores.size).round(2)
    end

    def summary_text
      return nil if @investigation.claim_assessments.empty?

      [
        "#{@investigation.claim_assessments.where(checkability_status: "checkable").count} checkable claims",
        "#{@investigation.claim_assessments.where(checkability_status: "not_checkable").count} not checkable",
        "#{@investigation.claim_assessments.where(verdict: "needs_more_evidence").count} still need more evidence"
      ].join(", ")
    end
  end
end
