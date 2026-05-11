module QueueMaintenance
  # Drops Turbo::Streams::BroadcastStreamJob entries that have been ready in the
  # queue for longer than `older_than`. A backlog of stale broadcasts builds up
  # while the worker is paused during a deploy; once delivered they only refresh
  # browsers that have long since reconnected to fresh state, so processing them
  # is wasted work that blocks real jobs behind them.
  class PurgeStaleBroadcasts
    BROADCAST_CLASS = "Turbo::Streams::BroadcastStreamJob".freeze
    DEFAULT_AGE = 5.minutes

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
        .where(solid_queue_jobs: { class_name: BROADCAST_CLASS })
        .where("solid_queue_jobs.created_at < ?", threshold)
        .pluck(:job_id)

      return 0 if job_ids.empty?

      SolidQueue::ReadyExecution.where(job_id: job_ids).delete_all

      # Only mark a job finished if it really left every execution table.
      # The worker may have raced us and claimed the row before our delete; in
      # that case the job is still live and we leave it alone.
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
