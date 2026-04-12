module Monitoring
  class SmokeCheck
    Result = Struct.new(:check_name, :status, :message, :duration_ms, keyword_init: true)

    CHECKS = %i[chromium_available content_extraction_shape llm_availability].freeze

    def self.run_all
      new.run_all
    end

    def run_all
      CHECKS.map { |check| run_check(check) }
    end

    private

    def run_check(name)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = send(name)
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).to_i
      result.duration_ms = elapsed
      result
    rescue => e
      Result.new(check_name: name.to_s, status: :error, message: "#{e.class}: #{e.message}", duration_ms: 0)
    end

    def chromium_available
      path = ENV.fetch("CHROMIUM_PATH", "chromium")
      stdout, _, status = Open3.capture3(path, "--headless=new", "--no-sandbox", "--dump-dom", "about:blank")

      if status.success? && stdout.include?("<html")
        Result.new(check_name: "chromium_available", status: :ok, message: "Chromium responding")
      else
        Result.new(check_name: "chromium_available", status: :fail, message: "Chromium not responding or not installed")
      end
    rescue Errno::ENOENT
      Result.new(check_name: "chromium_available", status: :fail, message: "Chromium binary not found at #{path}")
    end

    def content_extraction_shape
      html = <<~HTML
        <html><head><title>Smoke Check Article</title></head>
        <body><article>
          <p>This is a test paragraph for smoke check validation of the content extraction pipeline.</p>
          <p>Second paragraph to ensure minimum content length requirements are met properly.</p>
        </article></body></html>
      HTML

      result = Parsing::MainContentExtractor.call(html: html, url: "https://smoke-check.example.com/test")

      issues = []
      issues << "no title extracted" if result.title.blank?
      issues << "no body_text extracted" if result.body_text.blank?
      issues << "no excerpt generated" if result.excerpt.blank?
      issues << "unexpected main_content_path: #{result.main_content_path}" unless %w[article main body].include?(result.main_content_path.to_s)

      if issues.empty?
        Result.new(check_name: "content_extraction_shape", status: :ok, message: "Extraction shape valid")
      else
        Result.new(check_name: "content_extraction_shape", status: :degraded, message: "Issues: #{issues.join(', ')}")
      end
    end

    def llm_availability
      provider = Rails.application.config.x.frank_investigator.llm_provider
      models = Rails.application.config.x.frank_investigator.llm_models
      api_key = ENV[Llm::ProviderConfig.api_key_env]

      if api_key.blank?
        return Result.new(check_name: "llm_availability", status: :skip, message: "#{Llm::ProviderConfig.api_key_env} not configured")
      end

      if models.empty?
        return Result.new(check_name: "llm_availability", status: :fail, message: "No models configured")
      end

      Result.new(check_name: "llm_availability", status: :ok, message: "#{provider}: #{models.size} model(s) configured: #{models.join(', ')}")
    end
  end
end
