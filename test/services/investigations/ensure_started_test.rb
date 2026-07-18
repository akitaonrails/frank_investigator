require "test_helper"

class Investigations::EnsureStartedTest < ActiveSupport::TestCase
  test "creates investigation and article for new URL" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/ensure-new")

    assert investigation.persisted?
    assert_equal "https://example.com/ensure-new", investigation.normalized_url
    assert investigation.root_article.present?
    assert_equal "example.com", investigation.root_article.host
  end

  test "returns existing investigation for same URL" do
    first = Investigations::EnsureStarted.call(submitted_url: "https://example.com/ensure-same")
    second = Investigations::EnsureStarted.call(submitted_url: "https://example.com/ensure-same")

    assert_equal first.id, second.id
    assert_equal 1, Investigation.where(normalized_url: "https://example.com/ensure-same").count
  end

  test "enqueues KickoffJob" do
    assert_enqueued_with(job: Investigations::KickoffJob) do
      Investigations::EnsureStarted.call(submitted_url: "https://example.com/ensure-job")
    end
  end

  test "persists durable kickoff intent before a post-commit enqueue failure" do
    original = Investigations::KickoffJob.method(:perform_later)
    Investigations::KickoffJob.define_singleton_method(:perform_later) { |*| raise "adapter unavailable" }
    assert_raises(RuntimeError) { Investigations::EnsureStarted.call(submitted_url: "https://example.com/durable-kickoff") }

    investigation = Investigation.find_by!(normalized_url: "https://example.com/durable-kickoff")
    assert investigation.queued?
    assert_not_nil investigation.kickoff_due_at
    assert_nil investigation.kickoff_delivery_token
  ensure
    Investigations::KickoffJob.define_singleton_method(:perform_later, original) if original
  end

  test "does not enqueue kickoff again for an investigation already in progress" do
    article = Article.create!(url: "https://example.com/in-progress", normalized_url: "https://example.com/in-progress", host: "example.com")
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :processing
    )
    investigation.pipeline_steps.create!(name: "kickoff", status: :completed, finished_at: Time.current)

    assert_no_enqueued_jobs only: Investigations::KickoffJob do
      returned = Investigations::EnsureStarted.call(submitted_url: article.url)
      assert_equal investigation.id, returned.id
    end
  end

  test "classifies source metadata on article" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://www.congress.gov/bill/test")

    article = investigation.root_article
    assert_equal "legislative_record", article.source_kind
    assert_equal "primary", article.authority_tier
  end
end
