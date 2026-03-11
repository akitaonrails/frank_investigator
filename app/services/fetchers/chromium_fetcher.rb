require "open3"

module Fetchers
  class ChromiumFetcher
    FetchError = Class.new(StandardError)
    Snapshot = Struct.new(:html, :title, keyword_init: true)

    DEFAULT_FLAGS = [
      "--headless=new",
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--no-default-browser-check",
      "--window-size=1440,2200",
      "--virtual-time-budget=8000",
      "--dump-dom"
    ].freeze

    USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36".freeze

    def self.call(url)
      new.call(url)
    end

    def call(url)
      html, stderr, status = Open3.capture3(*command, url)
      raise FetchError, stderr.presence || "Chromium failed to fetch #{url}" unless status.success?

      document = Nokogiri::HTML(html)
      Snapshot.new(html:, title: document.at("title")&.text.to_s.squish)
    end

    private

    def command
      [browser_path, *DEFAULT_FLAGS, "--user-agent=#{USER_AGENT}"]
    end

    def browser_path
      ENV.fetch("CHROMIUM_PATH", "chromium")
    end
  end
end
