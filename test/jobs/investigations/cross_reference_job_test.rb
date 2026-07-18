require "test_helper"

class Investigations::CrossReferenceJobTest < ActiveJob::TestCase
  setup do
    @article = Article.create!(url: "https://cross-route.test/main", normalized_url: "https://cross-route.test/main",
      host: "cross-route.test", title: "Main", fetch_status: :fetched)
    @investigation = Investigation.create!(submitted_url: @article.url, normalized_url: @article.normalized_url,
      root_article: @article, status: :completed)
  end

  test "grouped investigations route enrichment through CAS and still auto-submit" do
    group = InvestigationGroup.create!(main_investigation: @investigation)
    @investigation.update!(investigation_group: group, group_membership_kind: :manual)
    assert_routed_without_direct_write
  end

  test "legacy parents route enrichment through CAS and still auto-submit" do
    child_article = Article.create!(url: "https://cross-route.test/child", normalized_url: "https://cross-route.test/child",
      host: "cross-route.test", title: "Child", fetch_status: :fetched)
    Investigation.create!(submitted_url: child_article.url, normalized_url: child_article.normalized_url,
      root_article: child_article, status: :completed, auto_submitted_from: @investigation)
    assert_routed_without_direct_write
  end

  private

  def assert_routed_without_direct_write
    original_index = Investigations::EmbeddingIndexer.method(:call)
    Investigations::EmbeddingIndexer.define_singleton_method(:call) { |**| nil }
    assert_enqueued_with(job: Investigations::RefreshParentEnrichmentJob, args: [ @investigation.id ]) do
      assert_enqueued_with(job: Investigations::AutoSubmitRelatedJob, args: [ @investigation.id ]) do
        Investigations::CrossReferenceJob.perform_now(@investigation.id)
      end
    end
    assert_nil @investigation.reload.event_context
  ensure
    Investigations::EmbeddingIndexer.define_singleton_method(:call, original_index)
  end
end
