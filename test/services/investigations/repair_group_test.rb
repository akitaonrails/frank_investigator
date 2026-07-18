require "test_helper"

class Investigations::RepairGroupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "dry run is a side effect free exact plan" do
    main = investigation("https://example.com/repair-main")
    peer = investigation("https://example.net/repair-peer")
    clear_enqueued_jobs
    timestamps = [ main.updated_at, peer.updated_at ]

    plan = Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [ "https://www.govinfo.gov/repair-source" ])

    assert_equal main.slug, plan[:proposed_owner]
    assert_equal [ main.slug, peer.slug ].sort, plan[:members].map { |m| m[:slug] }.sort
    assert_equal [ "https://www.govinfo.gov/repair-source" ], plan[:evidence].map { |e| e[:url] }
    assert_equal [ nil, nil ], [ main.reload.investigation_group_id, peer.reload.investigation_group_id ]
    assert_equal timestamps, [ main.updated_at, peer.updated_at ]
    assert_equal 0, enqueued_jobs.size
    assert plan[:fingerprint].present?
  end

  test "repair refuses a missing allowlisted investigation" do
    main = investigation("https://example.com/repair-existing")

    assert_raises(Investigations::GroupSubmissionPreflight::ConflictError) do
      Investigations::GroupSubmissionPreflight.call(main_url: main.normalized_url,
        news_urls: [ "https://example.net/not-an-investigation" ], evidence_urls: [], repair: true)
    end
  end

  test "preflight is deeply immutable and stale supplied plans are rejected" do
    main = investigation("https://example.com/repair-frozen")
    peer = investigation("https://example.net/repair-frozen-peer")
    preflight = Investigations::GroupSubmissionPreflight.call(main_url: main.normalized_url,
      news_urls: [ peer.normalized_url ], evidence_urls: [], repair: true)

    assert_raises(FrozenError) { preflight.news_urls << "https://example.org/nope" }
    assert_raises(FrozenError) { preflight.before.first[:url] << "x" }
    group = InvestigationGroup.create!(main_investigation: peer)
    peer.update!(investigation_group: group, group_membership_kind: :manual)
    assert_raises(Investigations::RepairGroup::ConflictError) do
      Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], preflight:)
    end
  end

  test "projection is deterministic, deeply frozen, and treats a nil due pending source as fetchable" do
    main = investigation("https://example.com/repair-projection-main")
    peer = investigation("https://example.net/repair-projection-peer")
    group = InvestigationGroup.create!(main_investigation: main)
    main.update!(investigation_group: group, group_membership_kind: :manual)
    peer.update!(investigation_group: group, group_membership_kind: :manual)
    source_article = Article.create!(url: "https://www.govinfo.gov/repair-nil-due", normalized_url: "https://www.govinfo.gov/repair-nil-due", host: "www.govinfo.gov")
    source = group.evidence_sources.create!(article: source_article, submitted_url: source_article.normalized_url, status: :pending)
    source.update_column(:fetch_retry_due_at, nil)
    at = Time.utc(2026, 1, 2, 3, 4, 5)
    clear_enqueued_jobs

    first = Investigations::RepairGroup.new(main:, news: [ peer ], evidence_urls: [ source_article.normalized_url ], apply: false).tap { |repair| repair.instance_variable_set(:@decision_at, at) }.call
    second = Investigations::RepairGroup.new(main:, news: [ peer ], evidence_urls: [ source_article.normalized_url ], apply: false).tap { |repair| repair.instance_variable_set(:@decision_at, at) }.call

    assert_equal first.to_h, second.to_h
    assert_includes first[:actions][:fetch], source_article.normalized_url
    assert first.frozen?
    assert first.plan[:actions].frozen?
    assert_raises(FrozenError) { first.plan[:actions][:fetch] << "https://example.org/nope" }
    assert_nil source.reload.fetch_retry_due_at
    assert_equal 0, enqueued_jobs.size
  end

  test "apply rejects projection drift under locks before it creates a group" do
    main = investigation("https://example.com/repair-drift-main")
    peer = investigation("https://example.net/repair-drift-peer")
    repair = Investigations::RepairGroup.new(main:, news: [ peer ], evidence_urls: [], apply: false)
    projection = repair.call
    main.update!(status: :failed)

    assert_raises(Investigations::RepairGroup::ConflictError) do
      Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], apply: true,
        preflight: repair.preflight)
    end
    assert_nil main.reload.investigation_group_id
    assert_nil peer.reload.investigation_group_id
    assert projection.frozen?
  end

  test "apply returns its original projection and durable committed intents" do
    main = investigation("https://example.com/repair-apply-main")
    peer = investigation("https://example.net/repair-apply-peer")
    dry = Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [])
    applied = Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], apply: true, expected_digest: dry.action_digest, decision_at: dry.decision_at)

    assert_equal dry[:input_digest], applied[:input_digest]
    assert applied[:applied]
    assert applied[:committed_intents].frozen?
    assert_equal main.reload.investigation_group_id, peer.reload.investigation_group_id
  end

  test "apply rejects missing, wrong, and future projection decisions before writes" do
    main = investigation("https://example.com/repair-guard-main")
    peer = investigation("https://example.net/repair-guard-peer")
    at = Time.current.change(usec: 0)
    dry = Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], decision_at: at)

    assert_raises(Investigations::RepairGroup::ConflictError) do
      Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], apply: true, decision_at: at)
    end
    assert_raises(Investigations::RepairGroup::ConflictError) do
      Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], apply: true, decision_at: at, expected_digest: "0" * 64)
    end
    assert_raises(Investigations::RepairGroup::ConflictError) do
      Investigations::RepairGroup.call(main:, news: [ peer ], evidence_urls: [], apply: true,
        decision_at: 6.seconds.from_now, expected_digest: dry.action_digest)
    end
    assert_nil main.reload.investigation_group_id
    assert_nil peer.reload.investigation_group_id
  end

  private

  def investigation(url)
    article = Article.create!(url:, normalized_url: url, host: URI(url).host)
    Investigation.create!(submitted_url: url, normalized_url: url, root_article: article)
  end
end
