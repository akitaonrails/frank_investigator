require "test_helper"

class Investigations::KickoffDeliveryPhase2dTest < ActiveJob::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test "expired lost kickoff lease is redelivered" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/phase2d-lost")
    clear_enqueued_jobs
    Investigations::KickoffDelivery.claim!(investigation)
    token = investigation.reload.kickoff_delivery_token
    investigation.update!(kickoff_delivery_expires_at: 1.second.ago)

    Investigations::RecoverExpiredGroupLeasesJob.perform_now
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == Investigations::KickoffJob && job[:args].first == investigation.id }
    assert_not_equal token, investigation.reload.kickoff_delivery_token
  end

  test "only matching delivery token acknowledges after root completion" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/phase2d-token")
    Investigations::KickoffDelivery.claim!(investigation)
    old_token = investigation.reload.kickoff_delivery_token
    investigation.update!(kickoff_delivery_expires_at: 1.second.ago)
    Investigations::KickoffDelivery.claim!(investigation)
    new_token = investigation.reload.kickoff_delivery_token

    Investigations::KickoffDelivery.acknowledge!(investigation, old_token)
    assert_equal new_token, investigation.reload.kickoff_delivery_token
    investigation.pipeline_steps.create!(name: "kickoff", status: :completed, finished_at: Time.current)
    Investigations::KickoffDelivery.acknowledge!(investigation, new_token)
    assert_nil investigation.reload.kickoff_delivery_token
    assert_nil investigation.kickoff_due_at
  end

  test "resubmitting existing pending nil-due evidence schedules and dispatches it once" do
    result = Investigations::SubmitGroup.call(main_url: "https://example.com/phase2d-main", evidence_urls: [ "https://www.govinfo.gov/phase2d-evidence" ])
    source = result.evidence_sources.first
    source.update!(fetch_delivery_token: nil, fetch_delivery_expires_at: nil, fetch_retry_due_at: nil)

    assert_enqueued_jobs 1, only: Investigations::FetchEvidenceJob do
      Investigations::SubmitGroup.call(main_url: "https://example.com/phase2d-main", evidence_urls: [ "https://www.govinfo.gov/phase2d-evidence" ])
    end
    source.reload
    assert_not_nil source.fetch_retry_due_at
  end

  test "future due and due-now active evidence leases are not bypassed" do
    result = Investigations::SubmitGroup.call(main_url: "https://example.com/phase2d-future", evidence_urls: [ "https://www.govinfo.gov/phase2d-future" ])
    source = result.evidence_sources.first
    source.update!(fetch_delivery_token: nil, fetch_delivery_expires_at: nil, fetch_retry_due_at: 1.hour.from_now)
    assert_no_enqueued_jobs only: Investigations::FetchEvidenceJob do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
    source.update!(fetch_delivery_token: "active", fetch_delivery_expires_at: 1.hour.from_now, fetch_retry_due_at: Time.current)
    assert_no_enqueued_jobs only: Investigations::FetchEvidenceJob do
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
    end
  end

  test "accepted but lost root handoff is recovered with a newer token" do
    investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/phase2d-lost-root")
    clear_enqueued_jobs
    Investigations::KickoffDelivery.claim!(investigation)
    old_token = investigation.reload.kickoff_delivery_token
    original = Investigations::FetchRootArticleJob.method(:perform_later)
    Investigations::FetchRootArticleJob.define_singleton_method(:perform_later) { |_id, _token| true }
    Investigations::KickoffJob.perform_now(investigation.id, old_token)
    assert_equal old_token, investigation.reload.kickoff_delivery_token
    investigation.update!(kickoff_delivery_expires_at: 1.second.ago)

    Investigations::FetchRootArticleJob.define_singleton_method(:perform_later, original)
    Investigations::RecoverExpiredGroupLeasesJob.perform_now
    delivery = enqueued_jobs.find { |job| job[:job] == Investigations::FetchRootArticleJob && job[:args].first == investigation.id }
    assert delivery
    refute_equal old_token, delivery[:args].second
    assert_equal delivery[:args].second, investigation.reload.kickoff_delivery_token
  ensure
    Investigations::FetchRootArticleJob.define_singleton_method(:perform_later, original) if original
  end

  test "completed root with lost acknowledgement recovers without repeating root work" do
    article = Article.create!(url: "https://example.com/phase2d-complete-root", normalized_url: "https://example.com/phase2d-complete-root", host: "example.com", fetch_status: :fetched, fetched_at: Time.current, body_text: "cached")
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.normalized_url, root_article: article, status: :processing, kickoff_due_at: Time.current)
    investigation.pipeline_steps.create!(name: "kickoff", status: :completed, finished_at: Time.current)
    investigation.pipeline_steps.create!(name: "fetch_root_article", status: :completed, finished_at: Time.current)
    Investigations::KickoffDelivery.claim!(investigation)
    old_token = investigation.reload.kickoff_delivery_token
    investigation.update!(kickoff_delivery_expires_at: 1.second.ago)
    clear_enqueued_jobs

    Investigations::RecoverExpiredGroupLeasesJob.perform_now
    delivery = enqueued_jobs.find { |job| job[:job] == Investigations::FetchRootArticleJob && job[:args].first == investigation.id }
    new_token = delivery[:args].second
    refute_equal old_token, new_token
    assert_no_difference -> { investigation.pipeline_steps.where(name: "fetch_root_article").count } do
      Investigations::FetchRootArticleJob.perform_now(investigation.id, new_token)
    end
    investigation.reload
    assert_nil investigation.kickoff_due_at
    assert_nil investigation.kickoff_delivery_token
    assert_not_nil investigation.kickoff_delivered_at
    assert_enqueued_jobs 3, only: [ Investigations::ExtractClaimsJob, Investigations::AnalyzeHeadlineJob, Investigations::ExpandLinkedArticlesJob ]
  end

  test "rolled back transaction leaves no durable kickoff intent" do
    assert_no_enqueued_jobs do
      assert_raises(RuntimeError) do
        Investigation.transaction do
        investigation = Investigations::EnsureStarted.call(submitted_url: "https://example.com/phase2d-rollback")
        Investigations::KickoffDelivery.schedule_in_transaction!(investigation)
        raise "rollback"
        end
      end
    end
    assert_nil Investigation.find_by(normalized_url: "https://example.com/phase2d-rollback")
  end
end
