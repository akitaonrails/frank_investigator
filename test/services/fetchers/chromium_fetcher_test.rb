require "test_helper"

class Fetchers::ChromiumFetcherTest < ActiveSupport::TestCase
  setup do
    @original_capture3 = Open3.method(:capture3)
  end

  teardown do
    Open3.define_singleton_method(:capture3, @original_capture3)
  end

  test "uses host-specific budget in command" do
    captured_cmd = nil
    html = "<html><head><title>Test Page</title></head><body><p>Content</p></body></html>"

    Open3.define_singleton_method(:capture3) do |*args|
      captured_cmd = args
      [html, "", Struct.new(:success?).new(true)]
    end

    Fetchers::ChromiumFetcher.call("https://g1.globo.com/economia/test")

    budget_flag = captured_cmd.find { |arg| arg.to_s.start_with?("--virtual-time-budget=") }
    assert_equal "--virtual-time-budget=25000", budget_flag
  end

  test "uses default budget for unknown hosts" do
    captured_cmd = nil
    html = "<html><head><title>Test</title></head><body><p>Content</p></body></html>"

    Open3.define_singleton_method(:capture3) do |*args|
      captured_cmd = args
      [html, "", Struct.new(:success?).new(true)]
    end

    Fetchers::ChromiumFetcher.call("https://example.com/article")

    budget_flag = captured_cmd.find { |arg| arg.to_s.start_with?("--virtual-time-budget=") }
    assert_equal "--virtual-time-budget=8000", budget_flag
  end

  test "includes stealth flag" do
    captured_cmd = nil
    html = "<html><head><title>Test</title></head><body><p>Content</p></body></html>"

    Open3.define_singleton_method(:capture3) do |*args|
      captured_cmd = args
      [html, "", Struct.new(:success?).new(true)]
    end

    Fetchers::ChromiumFetcher.call("https://example.com/test")

    assert captured_cmd.include?("--disable-blink-features=AutomationControlled")
  end

  test "retries with doubled budget on interstitial detection" do
    call_count = 0
    budgets = []
    interstitial_html = "<html><body>checking your browser before accessing</body></html>"
    clean_html = "<html><head><title>Clean</title></head><body><p>Real content</p></body></html>"

    Open3.define_singleton_method(:capture3) do |*args|
      call_count += 1
      budget_flag = args.find { |a| a.to_s.start_with?("--virtual-time-budget=") }
      budgets << budget_flag
      html = call_count == 1 ? interstitial_html : clean_html
      [html, "", Struct.new(:success?).new(true)]
    end

    result = Fetchers::ChromiumFetcher.call("https://example.com/test")
    assert_equal "Clean", result.title
    assert_equal 2, call_count
    assert_equal "--virtual-time-budget=8000", budgets[0]
    assert_equal "--virtual-time-budget=16000", budgets[1]
  end

  test "raises InterstitialDetectedError when retry also hits interstitial" do
    interstitial_html = "<html><body>cloudflare challenge-platform</body></html>"

    Open3.define_singleton_method(:capture3) do |*args|
      [interstitial_html, "", Struct.new(:success?).new(true)]
    end

    assert_raises(Fetchers::ChromiumFetcher::InterstitialDetectedError) do
      Fetchers::ChromiumFetcher.call("https://example.com/blocked")
    end
  end

  test "raises FetchError on chromium failure" do
    Open3.define_singleton_method(:capture3) do |*args|
      ["", "Process crashed", Struct.new(:success?).new(false)]
    end

    assert_raises(Fetchers::ChromiumFetcher::FetchError) do
      Fetchers::ChromiumFetcher.call("https://example.com/crash")
    end
  end

  test "rotates user agents across calls" do
    html = "<html><head><title>Test</title></head><body><p>Content</p></body></html>"
    agents = Set.new

    Open3.define_singleton_method(:capture3) do |*args|
      ua_flag = args.find { |a| a.to_s.start_with?("--user-agent=") }
      agents << ua_flag
      [html, "", Struct.new(:success?).new(true)]
    end

    20.times { Fetchers::ChromiumFetcher.call("https://example.com/test") }

    assert_operator agents.size, :>=, 2, "Expected at least 2 different user agents across 20 calls"
  end
end
