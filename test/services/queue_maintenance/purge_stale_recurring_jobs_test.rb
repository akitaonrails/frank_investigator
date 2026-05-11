require "test_helper"

class QueueMaintenance::PurgeStaleRecurringJobsTest < ActiveSupport::TestCase
  test "purges stale solid_queue_recurring ready jobs and marks them finished" do
    now = Time.zone.parse("2026-05-11 23:00:00 UTC")

    stale = create_ready_job(
      class_name: "SolidQueue::RecurringJob",
      queue: "solid_queue_recurring",
      created_at: now - 60.minutes
    )

    fresh = create_ready_job(
      class_name: "SolidQueue::RecurringJob",
      queue: "solid_queue_recurring",
      created_at: now - 1.minute
    )

    purged = QueueMaintenance::PurgeStaleRecurringJobs.call(older_than: 15.minutes, now:)

    assert_equal 1, purged
    assert_equal 0, SolidQueue::ReadyExecution.where(job_id: stale.id).count
    assert_equal now.to_i, stale.reload.finished_at.to_i
    assert_equal 1, SolidQueue::ReadyExecution.where(job_id: fresh.id).count
    assert_nil fresh.reload.finished_at
  end

  test "leaves jobs in other queues alone" do
    now = Time.zone.parse("2026-05-11 23:00:00 UTC")

    default_job = create_ready_job(
      class_name: "Investigations::ExtractClaimsJob",
      queue: "default",
      created_at: now - 60.minutes
    )

    QueueMaintenance::PurgeStaleRecurringJobs.call(older_than: 15.minutes, now:)

    assert_equal 1, SolidQueue::ReadyExecution.where(job_id: default_job.id).count
    assert_nil default_job.reload.finished_at
  end

  private

  def create_ready_job(class_name:, queue:, created_at:)
    job = SolidQueue::Job.create!(
      queue_name: queue,
      class_name: class_name,
      arguments: '{"arguments":[]}',
      created_at: created_at,
      updated_at: created_at
    )
    SolidQueue::ReadyExecution.find_or_create_by!(job_id: job.id) do |execution|
      execution.queue_name = queue
      execution.priority = 0
      execution.created_at = created_at
    end
    job
  end
end
