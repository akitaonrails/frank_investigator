require "test_helper"

class Investigations::RefreshParentEnrichmentJobTest < ActiveJob::TestCase
  setup do
    @parent_article = Article.create!(
      url: "https://parent.example/seed",
      normalized_url: "https://parent.example/seed",
      host: "parent.example",
      title: "Seed article",
      body_text: "Body of the parent investigation.",
      fetch_status: :fetched,
      fetched_at: Time.current
    )
    @parent = Investigation.create!(
      submitted_url: @parent_article.url,
      normalized_url: @parent_article.normalized_url,
      root_article: @parent_article,
      status: :completed,
      analysis_completed_at: 1.hour.ago
    )
  end

  test "is a no-op when the parent has no completed children" do
    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "ignored")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher_spy.calls
    assert_equal 0, headline_spy.calls
    assert_nil @parent.reload.last_enrichment_refresh_at
  end

  test "runs enricher and honest headline when a child completes" do
    create_child(slug: "child-1", completed_at: 5.minutes.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "A more honest headline")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 1, enricher_spy.calls
    assert_equal 1, headline_spy.calls

    @parent.reload
    assert_equal "A more honest headline", @parent.honest_headline
    assert_not_nil @parent.last_enrichment_refresh_at
  end

  test "is idempotent when no new child has completed since the last refresh" do
    create_child(slug: "child-old", completed_at: 30.minutes.ago)
    @parent.update_column(:last_enrichment_refresh_at, 10.minutes.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "should not run")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher_spy.calls, "enricher must not run when no newer child exists"
    assert_equal 0, headline_spy.calls
  end

  test "re-runs when a newer child completes after the previous refresh" do
    create_child(slug: "child-old", completed_at: 30.minutes.ago)
    @parent.update_column(:last_enrichment_refresh_at, 20.minutes.ago)
    create_child(slug: "child-new", completed_at: 1.minute.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "Updated headline")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 1, enricher_spy.calls
    assert_equal "Updated headline", @parent.reload.honest_headline
  end

  test "stamps refresh timestamp even when honest headline generator returns nil" do
    create_child(slug: "child-nil-headline", completed_at: 1.minute.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: nil)

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 1, enricher_spy.calls
    assert_nil @parent.reload.honest_headline
    assert_not_nil @parent.reload.last_enrichment_refresh_at
  end

  test "does nothing for a parent that is no longer marked completed" do
    @parent.update!(status: :processing)
    create_child(slug: "child-but-parent-processing", completed_at: 1.minute.ago)

    enricher_spy = SpyAnalyzer.new
    headline_spy = SpyAnalyzer.new(returns: "should not run")

    with_stubbed_analyzers(enricher: enricher_spy, headline: headline_spy) do
      Investigations::RefreshParentEnrichmentJob.perform_now(@parent.id)
    end

    assert_equal 0, enricher_spy.calls
    assert_equal 0, headline_spy.calls
  end

  private

  def create_child(slug:, completed_at:)
    article = Article.create!(
      url: "https://child.example/#{slug}",
      normalized_url: "https://child.example/#{slug}",
      host: "child.example",
      title: "Child #{slug}",
      body_text: "Body.",
      fetch_status: :fetched,
      fetched_at: Time.current
    )
    Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :completed,
      analysis_completed_at: completed_at,
      auto_submitted_from_id: @parent.id
    )
  end

  class SpyAnalyzer
    attr_reader :calls
    def initialize(returns: nil)
      @returns = returns
      @calls = 0
    end
    def call(**)
      @calls += 1
      @returns
    end
  end

  def with_stubbed_analyzers(enricher:, headline:)
    original_enricher = Analyzers::CrossInvestigationEnricher.method(:call)
    original_headline = Analyzers::HonestHeadlineGenerator.method(:call)
    Analyzers::CrossInvestigationEnricher.define_singleton_method(:call) { |**args| enricher.call(**args) }
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call) { |**args| headline.call(**args) }
    yield
  ensure
    Analyzers::CrossInvestigationEnricher.define_singleton_method(:call, original_enricher)
    Analyzers::HonestHeadlineGenerator.define_singleton_method(:call, original_headline)
  end
end
