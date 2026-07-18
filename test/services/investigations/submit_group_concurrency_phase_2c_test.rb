require "test_helper"

class Investigations::SubmitGroupConcurrencyPhase2cTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    @urls = []
  end

  teardown do
    clear_enqueued_jobs
    cleanup_phase_urls
    ActiveRecord::Base.connection_pool.release_connection
    ActiveJob::Base.queue_adapter = @adapter
  end

  test "identical all-new same-main plans converge to one exact group" do
    main, news = urls("same-main", 2)
    results = concurrently([ main, [ news ] ], [ main, [ news ] ])
    assert_successes(results)
    assert_equal 1, results.map { |r| r.group.id }.uniq.size
    assert_equal [ main, news ].sort, results.first.group.investigations.order(:normalized_url).pluck(:normalized_url)
  end

  test "conflicting same-main plans yield one exact winner and no union" do
    main, news_a, news_b = urls("conflict-main", 3)
    results = concurrently([ main, [ news_a ] ], [ main, [ news_b ] ])
    winner, loser = results.partition { |r| r.is_a?(Investigations::SubmitGroup::Result) }
    assert_equal 1, winner.size
    assert_equal 1, loser.size
    assert_kind_of Investigations::SubmitGroup::ConflictError, loser.first
    assert_includes [ [ main, news_a ].sort, [ main, news_b ].sort ], winner.first.group.investigations.order(:normalized_url).pluck(:normalized_url)
  end

  test "different mains sharing new news attaches shared investigation to at most one group" do
    main_a, main_b, shared = urls("shared-news", 3)
    results = concurrently([ main_a, [ shared ] ], [ main_b, [ shared ] ])
    assert_equal 1, results.count { |r| r.is_a?(Investigations::SubmitGroup::Result) }
    assert_equal 1, results.count { |r| r.is_a?(Investigations::SubmitGroup::ConflictError) }
    assert_operator Investigation.where(normalized_url: shared).joins(:investigation_group).count, :<=, 1
  end

  test "CAS RecordNotUnique and busy collisions rebuild the whole plan then converge" do
    [ Investigations::SubmitGroup::RetryableCollision, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid ].each do |error|
      main, news = urls("retry-#{error.name.demodulize}", 2)
      calls = 0
      with_acquire_failure(error, once: true) do
        result = Investigations::SubmitGroup.call(main_url: main, news_urls: [ news ])
        assert_equal [ main, news ].sort, result.group.investigations.order(:normalized_url).pluck(:normalized_url)
      end
    end
  end

  test "retry exhaustion raises conflict without domain records jobs or retained submission locks" do
    main, news = urls("exhaustion", 2)
    before_locks = InvestigationSubmissionLock.count
    with_acquire_failure(Investigations::SubmitGroup::RetryableCollision, once: false) do
      assert_raises(Investigations::SubmitGroup::ConflictError) { Investigations::SubmitGroup.call(main_url: main, news_urls: [ news ]) }
    end
    assert_equal 0, Investigation.where(normalized_url: [ main, news ]).count
    assert_equal 0, Article.where(normalized_url: [ main, news ]).count
    assert_equal before_locks, InvestigationSubmissionLock.count
    assert_no_enqueued_jobs
  end

  test "sqlite busy retry exhaustion leaves no domain or submission-lock residue" do
    main, news = urls("busy-exhaustion", 2)
    before_locks = InvestigationSubmissionLock.count
    with_acquire_failure(ActiveRecord::StatementInvalid, once: false) do
      assert_raises(Investigations::SubmitGroup::ConflictError) { Investigations::SubmitGroup.call(main_url: main, news_urls: [ news ]) }
    end
    assert_equal 0, Investigation.where(normalized_url: [ main, news ]).count
    assert_equal 0, Article.where(normalized_url: [ main, news ]).count
    assert_equal before_locks, InvestigationSubmissionLock.count
    assert_no_enqueued_jobs
  end

  test "outer rollback retains neither grouped domain state nor adapter work" do
    main, news, evidence = urls("outer-rollback", 3)
    before_locks = InvestigationSubmissionLock.count
    assert_no_enqueued_jobs do
      assert_raises(RuntimeError) do
        Investigation.transaction do
          Investigations::SubmitGroup.call(main_url: main, news_urls: [ news ], evidence_urls: [ evidence ])
          raise "rollback"
        end
      end
    end
    assert_equal 0, Investigation.where(normalized_url: [ main, news ]).count
    assert_equal 0, Article.where(normalized_url: [ main, news, evidence ]).count
    assert_equal 0, InvestigationGroupEvidenceSource.joins(:article).where(articles: { normalized_url: evidence }).count
    assert_equal before_locks, InvestigationSubmissionLock.count
  end

  private

  def urls(label, count)
    Array.new(count) { |i| url = "https://example#{i}.com/phase2c-#{label}-#{SecureRandom.hex(5)}"; @urls << url; url }
  end

  def concurrently(*plans)
    ready, release, results = Queue.new, Queue.new, Queue.new
    threads = plans.map do |main, news|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true; release.pop
          results << Investigations::SubmitGroup.call(main_url: main, news_urls: news)
        end
      rescue StandardError => error
        results << error
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end
    end
    plans.size.times { ready.pop }; plans.size.times { release << true }
    threads.each(&:join)
    plans.size.times.map { results.pop }
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  def assert_successes(results)
    results.each { |result| assert_kind_of Investigations::SubmitGroup::Result, result }
  end

  def with_acquire_failure(error, once:)
    original = Investigations::SubmitGroup.instance_method(:acquire_submission_locks!)
    calls = 0
    Investigations::SubmitGroup.define_method(:acquire_submission_locks!) do |plan|
      calls += 1
      if !once || calls == 1
        raise(error == ActiveRecord::StatementInvalid ? error.new("database is busy") : error)
      end
      original.bind_call(self, plan)
    end
    yield
  ensure
    Investigations::SubmitGroup.define_method(:acquire_submission_locks!, original) if original
  end

  def cleanup_phase_urls
    investigations = Investigation.where(normalized_url: @urls)
    InvestigationGroup.where(main_investigation_id: investigations.select(:id)).find_each(&:destroy!)
    investigations.find_each(&:destroy!)
    Article.where(normalized_url: @urls).find_each(&:destroy!)
    InvestigationSubmissionLock.where(key: @urls.map { |url| Digest::SHA256.hexdigest(url) }).delete_all
  rescue ActiveRecord::InvalidForeignKey
    # Tests must not hide a failed assertion behind cleanup; the suite's FK check
    # reports any remaining relationship.
  end
end
