require "test_helper"

class Investigations::GroupSubmissionPreflightPhase2aTest < ActiveSupport::TestCase
  test "preflight is read-only for accepted and rejected plans" do
    before = database_counts
    assert_no_enqueued_jobs do
      plan = Investigations::GroupSubmissionPreflight.call(main_url: "https://example.com/phase2a-main", news_urls: [ "https://example.net/phase2a-news" ], evidence_urls: [ "https://www.govinfo.gov/phase2a-evidence" ])
      assert plan.snapshot_valid?
    end
    assert_equal before, database_counts

    assert_raises(Investigations::GroupSubmissionPreflight::ConflictError) do
      Investigations::GroupSubmissionPreflight.call(main_url: "https://example.com/phase2a-overlap", evidence_urls: [ "https://example.com/phase2a-overlap" ])
    end
    assert_equal before, database_counts
  end

  test "applying equivalent evidence plans creates the same final URL set whether article is absent or unattached" do
    args = { main_url: "https://example.com/phase2a-snapshot", evidence_urls: [ "https://www.govinfo.gov/phase2a-existing" ] }
    absent = Investigations::SubmitGroup.call(**args)
    absent_urls = absent.evidence_sources.map { |s| s.article.normalized_url }
    Article.find_by!(normalized_url: args[:evidence_urls].first).destroy!
    InvestigationGroupEvidenceSource.where(investigation_group_id: absent.group.id).delete_all
    absent.group.destroy!
    Investigation.where(normalized_url: args[:main_url]).destroy_all
    Article.where(normalized_url: args[:main_url]).destroy_all
    Article.create!(url: args[:evidence_urls].first, normalized_url: args[:evidence_urls].first, host: "www.govinfo.gov")
    existing = Investigations::SubmitGroup.call(**args)
    assert_equal [ args[:evidence_urls].first ], absent_urls
    assert_equal [ args[:evidence_urls].first ], existing.evidence_sources.map { |s| s.article.normalized_url }
  end

  test "snapshot rejects owner member source reconciliation and lineage drift" do
    result = Investigations::SubmitGroup.call(main_url: "https://example.com/phase2a-owner", news_urls: [ "https://example.net/phase2a-member" ], evidence_urls: [ "https://www.govinfo.gov/phase2a-source" ])
    plan = Investigations::GroupSubmissionPreflight.call(main_url: "https://example.com/phase2a-owner", news_urls: [ "https://example.net/phase2a-member" ], evidence_urls: [ "https://www.govinfo.gov/phase2a-source" ])

    result.group.update!(enrichment_token: "changed")
    refute plan.snapshot_valid?
    result.group.update!(enrichment_token: nil)
    result.evidence_sources.first.update!(fetch_token: "changed")
    refute plan.snapshot_valid?
    result.evidence_sources.first.update!(fetch_token: nil)
    result.investigations.last.update!(reconciliation_token: "changed")
    refute plan.snapshot_valid?
    result.investigations.last.update!(reconciliation_token: nil)
    child = Investigations::EnsureStarted.call(submitted_url: "https://example.org/phase2a-child", auto_submitted_from: result.main_investigation)
    refute plan.snapshot_valid?
    assert child.persisted?
  end

  test "rejects true owner-only malformed groups and exact members with unrequested evidence" do
    owner = Investigations::EnsureStarted.call(submitted_url: "https://example.com/phase2a-malformed")
    group = InvestigationGroup.create!(main_investigation: owner)
    assert_raises(Investigations::GroupSubmissionPreflight::ConflictError) { Investigations::GroupSubmissionPreflight.call(main_url: owner.normalized_url) }

    result = Investigations::SubmitGroup.call(main_url: "https://example.com/phase2a-exact", news_urls: [ "https://example.net/phase2a-exact" ], evidence_urls: [ "https://www.govinfo.gov/phase2a-requested" ])
    extra = Article.create!(url: "https://www.govinfo.gov/phase2a-unrequested", normalized_url: "https://www.govinfo.gov/phase2a-unrequested", host: "www.govinfo.gov")
    result.group.evidence_sources.create!(article: extra, submitted_url: extra.url)
    assert_raises(Investigations::GroupSubmissionPreflight::ConflictError) do
      Investigations::GroupSubmissionPreflight.call(main_url: result.main_investigation.normalized_url, news_urls: [ "https://example.net/phase2a-exact" ], evidence_urls: [ "https://www.govinfo.gov/phase2a-requested" ])
    end
  end

  private

  def database_counts
    [ Article.count, Investigation.count, InvestigationGroup.count, InvestigationGroupEvidenceSource.count, InvestigationSubmissionLock.count ]
  end
end
