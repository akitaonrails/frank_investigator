if ENV["COVERAGE"] || ENV["CI"]
  require "simplecov"
  SimpleCov.start "rails" do
    enable_coverage :branch
    minimum_coverage line: 70, branch: 50
    skip "/test/"
    skip "/config/"
    skip "/db/"
  end
end

ENV["RAILS_ENV"] ||= "test"
ENV.delete("FRANK_AUTH_SECRET")   # Disable submission auth in tests
ENV.delete("JOBS_AUTH_PASSWORD")  # Reset to default "admin" for error_reports tests
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/llm_stubs"
require_relative "support/dns_stubs"

# WebMock: block external HTTP by default, allow localhost for internal services
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Tests always run in English regardless of the configured default locale
    setup do
      I18n.locale = :en
      LlmStubs.stub_openrouter!
      LlmStubs.stub_openrouter_models!
      LlmStubs.stub_web_searcher!
    end

    # Run tests in parallel with specified workers
    parallelize(workers: ENV["PARALLEL_WORKERS"]&.to_i || :number_of_processors)

    parallelize_setup do |worker|
      SimpleCov.command_name "#{SimpleCov.command_name}-#{worker}" if defined?(SimpleCov)
    end

    parallelize_teardown do
      SimpleCov.result if defined?(SimpleCov)
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
end

class ActiveSupport::TestCase
  include ActiveJob::TestHelper
end
