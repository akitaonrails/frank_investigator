require "test_helper"

class Investigations::ExtractClaimsJobTest < ActiveJob::TestCase
  setup do
    @previous_fetcher = Rails.application.config.x.frank_investigator.fetcher_class
    Rails.application.config.x.frank_investigator.fetcher_class = "Fetchers::FakeFetcher"
    Fetchers::FakeFetcher.clear
  end

  teardown do
    Rails.application.config.x.frank_investigator.fetcher_class = @previous_fetcher
    Fetchers::FakeFetcher.clear
  end

  test "extracts claims from root article and enqueues assessment" do
    investigation = create_fetched_investigation("https://example.com/extract-test")

    assert_enqueued_with(job: Investigations::AssessClaimsJob) do
      Investigations::ExtractClaimsJob.perform_now(investigation.id)
    end

    assert investigation.pipeline_steps.find_by(name: "extract_claims").completed?
    assert investigation.claim_assessments.any?
  end

  test "raises when root article is missing" do
    investigation = Investigation.create!(
      submitted_url: "https://example.com/no-root",
      normalized_url: "https://example.com/no-root"
    )

    assert_raises(RuntimeError) do
      Investigations::ExtractClaimsJob.perform_now(investigation.id)
    end
  end

  private

  def create_fetched_investigation(url)
    investigation = Investigations::EnsureStarted.call(submitted_url: url)
    perform_enqueued_jobs only: Investigations::KickoffJob

    Fetchers::FakeFetcher.register(url, html: <<~HTML)
      <html><head><title>Tax cuts announced for 2026</title></head>
      <body><article>
        <p>The government announced a 4 percent tax cut effective January 2026 according to the finance ministry.</p>
        <p>Officials confirmed the measure will affect 50 million taxpayers nationwide.</p>
      </article></body></html>
    HTML

    Investigations::FetchRootArticleJob.perform_now(investigation.id)
    investigation.reload
    investigation
  end
end
