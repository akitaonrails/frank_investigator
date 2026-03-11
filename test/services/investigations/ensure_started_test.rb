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

  test "classifies source metadata on article" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://www.congress.gov/bill/test")

    article = investigation.root_article
    assert_equal "legislative_record", article.source_kind
    assert_equal "primary", article.authority_tier
  end
end
