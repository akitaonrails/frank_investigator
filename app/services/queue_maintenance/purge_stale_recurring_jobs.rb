module QueueMaintenance
  # Drops Solid Queue recurring-task enqueues that have been waiting for longer
  # than `older_than`. Each scheduled tick creates a fresh job; if the worker is
  # paused (e.g. during a deploy) the backlog grows by one per tick per task,
  # and the next tick already supersedes the previous one for the cleanup and
  # recovery jobs we run on this app. Processing a missed tick from hours ago
  # is wasted work that blocks the current tick behind it.
  class PurgeStaleRecurringJobs
    QUEUE_NAME = "solid_queue_recurring".freeze
    DEFAULT_AGE = 15.minutes

    def self.call(older_than: DEFAULT_AGE, now: Time.current)
      new(older_than:, now:).call
    end

    def initialize(older_than:, now:)
      @older_than = older_than
      @now = now
    end

    def call
      threshold = @now - @older_than

      job_ids = SolidQueue::ReadyExecution.joins(:job)
        .where(solid_queue_jobs: { queue_name: QUEUE_NAME })
        .where("solid_queue_jobs.created_at < ?", threshold)
        .pluck(:job_id)

      return 0 if job_ids.empty?

      SolidQueue::ReadyExecution.where(job_id: job_ids).delete_all

      SolidQueue::Job.where(id: job_ids, finished_at: nil)
        .where.not(id: SolidQueue::ReadyExecution.select(:job_id))
        .where.not(id: SolidQueue::ClaimedExecution.select(:job_id))
        .where.not(id: SolidQueue::ScheduledExecution.select(:job_id))
        .where.not(id: SolidQueue::BlockedExecution.select(:job_id))
        .where.not(id: SolidQueue::FailedExecution.select(:job_id))
        .update_all(finished_at: @now, updated_at: @now)
    end
  end
end
