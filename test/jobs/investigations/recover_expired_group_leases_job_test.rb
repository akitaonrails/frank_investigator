require "test_helper"

class Investigations::RecoverExpiredGroupLeasesJobTest < ActiveJob::TestCase
  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "backfills a legacy queued investigation with no kickoff marker" do
    article = Article.create!(url: "https://example.com/legacy-kickoff", normalized_url: "https://example.com/legacy-kickoff", host: "example.com")
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article)

    assert_enqueued_with(job: Investigations::KickoffJob, args: ->(args) { args.first == investigation.id }) do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
    investigation.reload
    assert_not_nil investigation.kickoff_due_at
    assert_not_nil investigation.kickoff_delivery_token
  end
end
