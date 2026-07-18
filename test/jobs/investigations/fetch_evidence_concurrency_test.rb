require "test_helper"

class FetchEvidenceConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @previous_fetcher = Rails.application.config.x.frank_investigator.fetcher_class
    Rails.application.config.x.frank_investigator.fetcher_class = "ConcurrentEvidenceFetcher"
    token = SecureRandom.hex
    @investigation = Investigation.create!(submitted_url: "https://news.test/#{token}", normalized_url: "https://news.test/#{token}")
    @group = InvestigationGroup.create!(main_investigation: @investigation)
    @investigation.update!(investigation_group: @group, group_membership_kind: :manual)
    @articles = 2.times.map do |index|
      Article.create!(url: "https://www.whitehouse.gov/briefing-room/concurrent-#{token}-#{index}", normalized_url: "https://www.whitehouse.gov/briefing-room/concurrent-#{token}-#{index}", host: "www.whitehouse.gov")
    end
    @sources = @articles.map { |article| InvestigationGroupEvidenceSource.create!(investigation_group: @group, article:, submitted_url: article.url) }
  end

  teardown do
    Rails.application.config.x.frank_investigator.fetcher_class = @previous_fetcher
    InvestigationGroupEvidenceSource.where(id: @sources.map(&:id)).delete_all
    PipelineStep.where(investigation_id: @investigation.id).delete_all
    Investigation.where(id: @investigation.id).update_all(investigation_group_id: nil)
    InvestigationGroup.where(id: @group.id).delete_all
    Investigation.where(id: @investigation.id).delete_all
    HtmlSnapshot.where(article_id: @articles.map(&:id)).delete_all
    ArticleLink.where(source_article_id: @articles.map(&:id)).or(ArticleLink.where(target_article_id: @articles.map(&:id))).delete_all
    Article.where(id: @articles.map(&:id)).delete_all
  end

  test "two public jobs stage then concurrently publish through separate connections without a lost revision" do
    barrier = ThreadBarrier.new(2)
    original = Investigations::FetchEvidenceJob.instance_method(:publish!)
    Investigations::FetchEvidenceJob.define_method(:publish!) do |source, token, staged|
      barrier.wait
      original.bind_call(self, source, token, staged)
    end
    errors = Queue.new
    threads = @sources.map do |source|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Investigations::FetchEvidenceJob.perform_now(source.id)
        end
      rescue StandardError => error
        errors << error
      end
    end
    threads.each(&:join)

    assert_empty errors.size.times.map { errors.pop }
    assert_equal 2, @group.reload.evidence_revision
    assert_equal [ "ready", "ready" ], @sources.map { |source| source.reload.status }.sort
    refute_equal @sources[0].reload.content_fingerprint, @sources[1].reload.content_fingerprint
    @investigation.pipeline_steps.create!(name: "generate_summary", status: :completed)
    Investigations::RecoverExpiredGroupLeasesJob.perform_now
    Investigations::ReconcileGroupEvidenceJob.perform_now(@investigation.id)
    assert_equal 2, @investigation.reload.evidence_revision_assessed
  ensure
    Investigations::FetchEvidenceJob.define_method(:publish!, original) if original
  end

  class ThreadBarrier
    def initialize(count)
      @count = count
      @arrived = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def wait
      @mutex.synchronize do
        @arrived += 1
        @arrived == @count ? @condition.broadcast : @condition.wait(@mutex)
      end
    end
  end
end

class ConcurrentEvidenceFetcher
  def self.call(url)
    index = url[/concurrent-[^-]+-(\d+)\z/, 1]
    html = <<~HTML
      <html><head><title>Concurrent official #{index}</title><meta property="og:type" content="article"></head>
      <body><article><h1>Concurrent official #{index}</h1><p>#{"This independently documented official record supplies detailed evidence number #{index}. " * 12}</p></article></body></html>
    HTML
    Fetchers::ChromiumFetcher::Snapshot.new(html:, title: "Concurrent official #{index}")
  end
end
