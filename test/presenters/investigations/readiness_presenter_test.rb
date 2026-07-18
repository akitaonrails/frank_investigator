require "test_helper"

class Investigations::ReadinessPresenterTest < ActiveSupport::TestCase
  test "standalone processing and completed readiness" do
    processing = investigation("processing", status: :processing)
    completed = investigation("completed")

    assert_equal({ pipeline_ready: false, evidence_current: true, ready: false, group: nil }, presenter(processing))
    assert_equal true, presenter(completed)[:pipeline_ready]
    assert_equal true, presenter(completed)[:evidence_current]
    assert_equal true, presenter(completed)[:ready]
  end

  test "pending evidence and stale manual assessments are not current" do
    main, group = grouped_main(revision: 1)
    evidence(group, status: :pending)
    assert_equal false, presenter(main)[:evidence_current]
    group.evidence_sources.first.update!(status: :ready, ready_at: Time.current)
    investigation("stale-member", group:, assessed: 0)
    main.reload
    assert_equal false, presenter(main)[:evidence_current]
  end

  test "all manual members assessed against ready evidence are current" do
    main, group = grouped_main(revision: 1)
    member = investigation("member", group:, assessed: 1)
    evidence(group, status: :ready)
    result = presenter(main)
    assert_equal true, result[:ready]
    assert_equal [ main.id, member.id ], result[:group][:members].map { |item| item[:id] }
  end

  test "only terminal failed or rejected evidence is complete; retry and active states are not" do
    main, group = grouped_main(revision: 0)
    source = evidence(group, status: :failed, terminal_at: Time.current)
    assert_equal true, presenter(main)[:evidence_current]
    source.update!(fetch_retry_due_at: Time.current)
    assert_equal false, presenter(main)[:evidence_current]
    [ :pending, :fetching ].each do |status|
      source.update!(status:, fetch_retry_due_at: nil, fetch_token: nil, fetch_lease_expires_at: nil, fetch_delivery_token: nil, fetch_delivery_expires_at: nil)
      assert_equal false, presenter(main)[:evidence_current]
    end
    source.update!(status: :rejected, terminal_at: Time.current, fetch_delivery_token: "active", fetch_delivery_expires_at: 1.minute.from_now)
    assert_equal false, presenter(main)[:evidence_current]
  end

  test "terminal rejected evidence is settled and group entries never recurse" do
    main, group = grouped_main(revision: 0)
    evidence(group, status: :rejected, terminal_at: Time.current)
    payload = presenter(main)

    assert_equal true, payload[:evidence_current]
    payload[:group][:members].each do |member|
      refute member.key?(:group)
      refute member.key?(:members)
      refute member.key?(:investigation)
    end
    payload[:group][:evidence].each do |source|
      refute source.key?(:group)
      refute source.key?(:members)
      refute source.key?(:investigation)
    end
  end

  test "group payload has deterministic main-first member and normalized evidence order" do
    main, group = grouped_main(revision: 0)
    later = investigation("z-member", group:, assessed: 0)
    evidence(group, url: "https://z.example/evidence", status: :ready)
    evidence(group, url: "https://a.example/evidence", status: :ready)
    payload = presenter(main)[:group]
    assert_equal main.slug, payload[:main_investigation][:slug]
    assert_equal [ main.id, later.id ], payload[:members].map { |member| member[:id] }
    assert_equal [ "https://a.example/evidence", "https://z.example/evidence" ], payload[:evidence].map { |item| item[:normalized_url] }
    assert_equal true, payload[:members].first[:main]
  end

  private

  def presenter(investigation) = Investigations::ReadinessPresenter.call(investigation)

  def grouped_main(revision:)
    main = investigation("main", assessed: revision)
    group = InvestigationGroup.create!(main_investigation: main, evidence_revision: revision)
    main.update!(investigation_group: group, group_membership_kind: :manual)
    [ main, group ]
  end

  def investigation(seed, group: nil, assessed: 0, status: :completed)
    url = "https://#{seed}.example/article"
    article = Article.create!(url:, normalized_url: url, host: "#{seed}.example", fetch_status: :fetched)
    Investigation.create!(submitted_url: url, normalized_url: url, root_article: article, status:, investigation_group: group,
                          group_membership_kind: group ? :manual : nil, evidence_revision_assessed: assessed)
  end

  def evidence(group, url: "https://evidence.example/article", status:, terminal_at: nil)
    article = Article.create!(url:, normalized_url: url, host: URI(url).host, fetch_status: :fetched)
    group.evidence_sources.create!(article:, submitted_url: url, status:, ready_at: status == :ready ? Time.current : nil, terminal_at:)
  end
end
