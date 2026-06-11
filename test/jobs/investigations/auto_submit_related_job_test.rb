require "test_helper"

class Investigations::AutoSubmitRelatedJobTest < ActiveJob::TestCase
  setup do
    @parent_article = Article.create!(
      url: "https://parent.example/seed",
      normalized_url: "https://parent.example/seed",
      host: "parent.example",
      title: "Seed article",
      body_text: "Parent body text covering the event of interest.",
      fetch_status: :fetched,
      fetched_at: Time.current
    )
    @parent = Investigation.create!(
      submitted_url: @parent_article.url,
      normalized_url: @parent_article.normalized_url,
      root_article: @parent_article,
      status: :completed,
      analysis_completed_at: Time.current
    )
  end

  test "submits up to the configured cap with one investigation per outlet" do
    coverage = [
      { "url" => "https://outlet-a.com/story-1", "title" => "A1", "snippet" => "" },
      { "url" => "https://outlet-a.com/story-2", "title" => "A2", "snippet" => "" }, # dup host, skipped
      { "url" => "https://outlet-b.com/story-1", "title" => "B1", "snippet" => "" },
      { "url" => "https://outlet-c.com/story-1", "title" => "C1", "snippet" => "" },
      { "url" => "https://outlet-d.com/story-1", "title" => "D1", "snippet" => "" },
      { "url" => "https://outlet-e.com/story-1", "title" => "E1", "snippet" => "" },
      { "url" => "https://outlet-f.com/story-1", "title" => "F1", "snippet" => "" } # beyond cap
    ]
    @parent.update!(coordinated_narrative: { "similar_coverage" => coverage })

    Investigations::AutoSubmitRelatedJob.perform_now(@parent.id)

    submitted = Investigation.where(auto_submitted_from_id: @parent.id)
    assert_equal 5, submitted.count
    hosts = submitted.includes(:root_article).map { |inv| inv.root_article.host }
    assert_equal %w[outlet-a.com outlet-b.com outlet-c.com outlet-d.com outlet-e.com], hosts.sort
  end

  test "tags children with the parent investigation id" do
    @parent.update!(coordinated_narrative: { "similar_coverage" => [
      { "url" => "https://otheroutlet.example/article" }
    ] })

    Investigations::AutoSubmitRelatedJob.perform_now(@parent.id)

    child = Investigation.find_by(normalized_url: "https://otheroutlet.example/article")
    assert_not_nil child
    assert_equal @parent.id, child.auto_submitted_from_id
  end

  test "skips candidates from the parent's own host" do
    @parent.update!(coordinated_narrative: { "similar_coverage" => [
      { "url" => "https://parent.example/another-story" }, # same host, must skip
      { "url" => "https://different.example/story" }
    ] })

    Investigations::AutoSubmitRelatedJob.perform_now(@parent.id)

    assert_equal 1, Investigation.where(auto_submitted_from_id: @parent.id).count
    assert Investigation.exists?(normalized_url: "https://different.example/story")
    assert_not Investigation.exists?(normalized_url: "https://parent.example/another-story")
  end

  test "skips URLs that are already investigated" do
    Investigation.create!(
      submitted_url: "https://existing.example/article",
      normalized_url: "https://existing.example/article",
      status: :completed
    )
    @parent.update!(coordinated_narrative: { "similar_coverage" => [
      { "url" => "https://existing.example/article" },
      { "url" => "https://fresh.example/article" }
    ] })

    Investigations::AutoSubmitRelatedJob.perform_now(@parent.id)

    assert_nil Investigation.find_by(normalized_url: "https://existing.example/article").auto_submitted_from_id
    assert_equal @parent.id, Investigation.find_by(normalized_url: "https://fresh.example/article").auto_submitted_from_id
  end

  test "respects FRANK_INVESTIGATOR_AUTO_SUBMIT_MAX override" do
    original = ENV["FRANK_INVESTIGATOR_AUTO_SUBMIT_MAX"]
    ENV["FRANK_INVESTIGATOR_AUTO_SUBMIT_MAX"] = "2"
    @parent.update!(coordinated_narrative: { "similar_coverage" => [
      { "url" => "https://a.example/x" }, { "url" => "https://b.example/x" },
      { "url" => "https://c.example/x" }, { "url" => "https://d.example/x" }
    ] })

    Investigations::AutoSubmitRelatedJob.perform_now(@parent.id)

    assert_equal 2, Investigation.where(auto_submitted_from_id: @parent.id).count
  ensure
    ENV["FRANK_INVESTIGATOR_AUTO_SUBMIT_MAX"] = original
  end
end
