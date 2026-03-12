require "test_helper"

class Pipeline::StepRunnerFullTest < ActiveSupport::TestCase
  setup do
    @root = Article.create!(url: "https://ex.com/sr", normalized_url: "https://ex.com/sr", host: "ex.com")
    @investigation = Investigation.create!(submitted_url: @root.url, normalized_url: @root.normalized_url, root_article: @root)
  end

  test "creates step and marks as completed on success" do
    result = Pipeline::StepRunner.call(investigation: @investigation, name: "test_step") do
      { result: "ok" }
    end

    assert result.executed
    step = result.step
    assert_equal "completed", step.status
    assert step.finished_at.present?
    assert_equal({ "result" => "ok" }, step.result_json)
  end

  test "marks step as failed when block raises" do
    assert_raises(RuntimeError) do
      Pipeline::StepRunner.call(investigation: @investigation, name: "fail_step") do
        raise "something broke"
      end
    end

    step = @investigation.pipeline_steps.find_by!(name: "fail_step")
    assert_equal "failed", step.status
    assert_equal "RuntimeError", step.error_class
    assert_equal "something broke", step.error_message
    assert step.finished_at.present?
  end

  test "skips completed step without allow_rerun" do
    Pipeline::StepRunner.call(investigation: @investigation, name: "once_step") { { first: true } }
    executions = 0

    result = Pipeline::StepRunner.call(investigation: @investigation, name: "once_step") do
      executions += 1
    end

    assert_not result.executed
    assert_equal 0, executions
  end

  test "re-executes completed step with allow_rerun" do
    Pipeline::StepRunner.call(investigation: @investigation, name: "rerun_step") { { first: true } }
    executions = 0

    result = Pipeline::StepRunner.call(investigation: @investigation, name: "rerun_step", allow_rerun: true) do
      executions += 1
      { second: true }
    end

    assert result.executed
    assert_equal 1, executions
  end

  test "increments attempts_count on each execution" do
    Pipeline::StepRunner.call(investigation: @investigation, name: "attempt_step", allow_rerun: true) { {} }
    Pipeline::StepRunner.call(investigation: @investigation, name: "attempt_step", allow_rerun: true) { {} }

    step = @investigation.pipeline_steps.find_by!(name: "attempt_step")
    assert_equal 2, step.attempts_count
  end

  test "skips running step that is not stale" do
    step = @investigation.pipeline_steps.create!(
      name: "running_step", status: :running,
      started_at: 1.minute.ago, attempts_count: 1
    )
    executions = 0

    result = Pipeline::StepRunner.call(investigation: @investigation, name: "running_step") do
      executions += 1
    end

    assert_not result.executed
    assert_equal 0, executions
  end

  test "reclaims stale running step" do
    step = @investigation.pipeline_steps.create!(
      name: "stale_step", status: :running,
      started_at: 15.minutes.ago, attempts_count: 1
    )

    result = Pipeline::StepRunner.call(investigation: @investigation, name: "stale_step") do
      { reclaimed: true }
    end

    assert result.executed
    step.reload
    assert_equal "completed", step.status
  end

  test "enforces step budget" do
    Pipeline::StepRunner::MAX_STEPS_PER_INVESTIGATION.times do |i|
      @investigation.pipeline_steps.create!(name: "step_#{i}", status: :completed)
    end

    assert_raises(Pipeline::StepRunner::BudgetExceededError) do
      Pipeline::StepRunner.call(investigation: @investigation, name: "one_too_many") { {} }
    end
  end

  test "clears error fields on re-execution" do
    assert_raises(RuntimeError) do
      Pipeline::StepRunner.call(investigation: @investigation, name: "retry_step") { raise "fail" }
    end

    step = @investigation.pipeline_steps.find_by!(name: "retry_step")
    assert_equal "RuntimeError", step.error_class

    Pipeline::StepRunner.call(investigation: @investigation, name: "retry_step", allow_rerun: true) { { ok: true } }
    step.reload

    assert_equal "completed", step.status
    assert_nil step.error_class
    assert_nil step.error_message
  end
end
