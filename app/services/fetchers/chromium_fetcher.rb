require "open3"
require "timeout"

module Fetchers
  class ChromiumFetcher
    FetchError = Class.new(StandardError)
    InterstitialDetectedError = Class.new(FetchError)
    Snapshot = Struct.new(:html, :title, keyword_init: true)

    BASE_FLAGS = [
      "--headless=new",
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--no-default-browser-check",
      "--window-size=1440,2200",
      "--disable-blink-features=AutomationControlled",
      "--dump-dom"
    ].freeze

    USER_AGENTS = [
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
    ].freeze

    INTERSTITIAL_PATTERN = /challenge-platform|cloudflare|captcha|checking your browser|aguarde.*verificando/i

    def self.call(url)
      new.call(url)
    end

    def call(url)
      profile = HostProfile.for(url)
      budget = profile[:budget]

      html, title = fetch_with_budget(url, budget)

      if html.match?(INTERSTITIAL_PATTERN)
        html, title = fetch_with_budget(url, budget * 2)
        raise InterstitialDetectedError, "Interstitial/challenge page detected for #{url}" if html.match?(INTERSTITIAL_PATTERN)
      end

      Snapshot.new(html:, title:)
    end

    private

    def fetch_with_budget(url, budget)
      timeout_seconds = (budget / 1000) + 30
      ua = USER_AGENTS.sample

      cmd = [browser_path, *BASE_FLAGS, "--virtual-time-budget=#{budget}", "--user-agent=#{ua}"]

      html, stderr, status = Timeout.timeout(timeout_seconds) do
        Open3.capture3(*cmd, url)
      end

      raise FetchError, stderr.presence || "Chromium failed to fetch #{url}" unless status.success?

      document = Nokogiri::HTML(html)
      [html, document.at("title")&.text.to_s.squish]
    end

    def browser_path
      ENV.fetch("CHROMIUM_PATH", "chromium")
    end
  end
end
