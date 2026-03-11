require "test_helper"

class Investigations::KickoffJobTest < ActiveJob::TestCase
  test "transitions investigation to processing and enqueues fetch" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/kickoff-test")
    perform_enqueued_jobs only: Investigations::KickoffJob

    investigation.reload
    assert_equal "processing", investigation.status
    assert investigation.pipeline_steps.find_by(name: "kickoff").completed?
  end

  test "enqueues FetchRootArticleJob" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/kickoff-enqueue")

    assert_enqueued_with(job: Investigations::FetchRootArticleJob) do
      perform_enqueued_jobs only: Investigations::KickoffJob
    end
  end

  test "is idempotent when run twice" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/kickoff-idem")
    perform_enqueued_jobs only: Investigations::KickoffJob
    perform_enqueued_jobs only: Investigations::KickoffJob

    assert_equal 1, investigation.pipeline_steps.where(name: "kickoff").count
  end
end
