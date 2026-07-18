require "test_helper"

class Investigations::SubmitGroupTest < ActiveSupport::TestCase
  test "creates manual members and evidence without an evidence investigation" do
    result = Investigations::SubmitGroup.call(
      main_url: "https://example.com/main-group-test",
      news_urls: "https://example.net/peer-group-test\nhttps://example.org/peer-group-test",
      evidence_urls: "https://www.govinfo.gov/evidence-group-test"
    )

    assert_equal 3, result.group.investigations.count
    assert_equal 1, result.group.evidence_sources.count
    evidence_article = result.evidence_sources.first.article
    assert_not Investigation.exists?(normalized_url: evidence_article.normalized_url)
    assert result.group.main_investigation.group_membership_kind_manual?
  end

  test "rejects role overlap and malformed list values" do
    assert_raises(Investigations::SubmitGroup::ConflictError) do
      Investigations::SubmitGroup.call(main_url: "https://example.com/role-test", evidence_urls: [ "https://example.com/role-test" ])
    end
    assert_raises(ArgumentError) do
      Investigations::SubmitGroup.call(main_url: "https://example.com/type-test", news_urls: { bad: "type" })
    end
  end

  test "flattens textarea arrays and treats normalized duplicates once" do
    result = Investigations::SubmitGroup.call(
      main_url: "https://example.com/preflight-main",
      news_urls: [ [ "https://example.net/preflight-peer\n https://example.org/preflight-peer " ] ],
      evidence_urls: [ "https://www.govinfo.gov/preflight-evidence\n" ]
    )

    assert_equal 3, result.group.investigations.count
    assert_equal 1, result.group.evidence_sources.count
  end

  test "canonical plan removes main repeated as news and blank lists stay standalone" do
    plan = Investigations::GroupSubmissionPreflight.call(
      main_url: "HTTPS://example.com:443/canonical#fragment",
      news_urls: [ "https://example.com/canonical\r\n" ], evidence_urls: [ "\n" ]
    )
    assert_equal plan.main_url, plan.desired_urls.first
    assert_empty plan.news_urls
    assert_not plan.grouped?

    investigation = Investigations::SubmitGroup.call(main_url: "https://example.com/standalone", news_urls: [ "\n" ], evidence_urls: [])
    assert_nil investigation.investigation_group
  end

  test "durably schedules every grouped member before the first enqueue attempt" do
    original = Investigations::KickoffJob.method(:perform_later)
    Investigations::KickoffJob.define_singleton_method(:perform_later) { |*| raise "adapter unavailable" }
    assert_raises(RuntimeError) do
      Investigations::SubmitGroup.call(main_url: "https://example.com/durable-main", news_urls: [ "https://example.net/durable-peer" ])
    end

    members = Investigation.where(normalized_url: [ "https://example.com/durable-main", "https://example.net/durable-peer" ])
    assert_equal 2, members.count
    assert_equal 2, members.where.not(kickoff_due_at: nil).count
  ensure
    Investigations::KickoffJob.define_singleton_method(:perform_later, original) if original
  end
end
