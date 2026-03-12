module Pipeline
  class StepRunner
    STALE_AFTER = 10.minutes
    MAX_STEPS_PER_INVESTIGATION = 50

    Result = Struct.new(:step, :executed, keyword_init: true)
    class BudgetExceededError < StandardError; end

    def self.call(investigation:, name:, allow_rerun: false, &block)
      new(investigation:, name:, allow_rerun:).call(&block)
    end

    def initialize(investigation:, name:, allow_rerun:)
      @investigation = investigation
      @name = name
      @allow_rerun = allow_rerun
    end

    def call
      step = find_or_create_step!

      step.with_lock do
        step.reload
        return Result.new(step:, executed: false) if step.completed? && !@allow_rerun
        return Result.new(step:, executed: false) if step.running? && !stale?(step)

        step.update!(
          status: :running,
          attempts_count: step.attempts_count + 1,
          started_at: step.started_at || Time.current,
          error_class: nil,
          error_message: nil
        )
      end

      result_json = yield(step) || {}
      step.reload
      step.update!(status: :completed, finished_at: Time.current, result_json:)

      Result.new(step:, executed: true)
    rescue StandardError => error
      step&.reload
      step&.update!(
        status: :failed,
        finished_at: Time.current,
        error_class: error.class.name,
        error_message: error.message
      )
      raise
    end

    private

    def find_or_create_step!
      enforce_budget!
      @investigation.pipeline_steps.find_or_create_by!(name: @name)
    rescue ActiveRecord::RecordNotUnique
      @investigation.pipeline_steps.find_by!(name: @name)
    end

    def enforce_budget!
      step_count = @investigation.pipeline_steps.count
      if step_count >= MAX_STEPS_PER_INVESTIGATION
        raise BudgetExceededError, "Investigation has reached the maximum of #{MAX_STEPS_PER_INVESTIGATION} pipeline steps"
      end
    end

    def stale?(step)
      step.started_at.blank? || step.started_at < STALE_AFTER.ago
    end
  end
end
