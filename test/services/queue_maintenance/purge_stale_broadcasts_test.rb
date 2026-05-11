require "test_helper"

class QueueMaintenance::PurgeStaleBroadcastsTest < ActiveSupport::TestCase
  test "purges stale ready broadcast jobs and marks them finished" do
    now = Time.zone.parse("2026-05-11 23:00:00 UTC")

    stale = create_ready_job(
      class_name: "Turbo::Streams::BroadcastStreamJob",
      queue: "realtime",
      created_at: now - 30.minutes
    )

    fresh = create_ready_job(
      class_name: "Turbo::Streams::BroadcastStreamJob",
      queue: "realtime",
      created_at: now - 1.minute
    )

    purged = QueueMaintenance::PurgeStaleBroadcasts.call(older_than: 5.minutes, now:)

    assert_equal 1, purged
    assert_equal 0, SolidQueue::ReadyExecution.where(job_id: stale.id).count
    assert_equal now.to_i, stale.reload.finished_at.to_i
    assert_equal 1, SolidQueue::ReadyExecution.where(job_id: fresh.id).count
    assert_nil fresh.reload.finished_at
  end

  test "leaves non-broadcast jobs alone even when stale" do
    now = Time.zone.parse("2026-05-11 23:00:00 UTC")

    investigation_job = create_ready_job(
      class_name: "Investigations::ExtractClaimsJob",
      queue: "default",
      created_at: now - 30.minutes
    )

    purged = QueueMaintenance::PurgeStaleBroadcasts.call(older_than: 5.minutes, now:)

    assert_equal 0, purged
    assert_equal 1, SolidQueue::ReadyExecution.where(job_id: investigation_job.id).count
    assert_nil investigation_job.reload.finished_at
  end

  test "leaves broadcasts that have already been claimed alone" do
    now = Time.zone.parse("2026-05-11 23:00:00 UTC")

    process = SolidQueue::Process.create!(
      kind: "Worker",
      name: "test-worker",
      hostname: "localhost",
      pid: 12345,
      last_heartbeat_at: now,
      created_at: now - 5.minutes
    )

    claimed = SolidQueue::Job.create!(
      queue_name: "realtime",
      class_name: "Turbo::Streams::BroadcastStreamJob",
      arguments: '{"arguments":[]}',
      created_at: now - 30.minutes,
      updated_at: now - 30.minutes
    )
    # Race: dispatcher already moved it to claimed before our purge runs.
    SolidQueue::ClaimedExecution.create!(
      job_id: claimed.id,
      process_id: process.id,
      created_at: now - 1.minute
    )

    QueueMaintenance::PurgeStaleBroadcasts.call(older_than: 5.minutes, now:)

    assert_nil claimed.reload.finished_at, "should not mark a claimed job finished"
    assert SolidQueue::ClaimedExecution.exists?(job_id: claimed.id)
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
