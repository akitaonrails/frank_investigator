if ENV["COVERAGE"] || ENV["CI"]
  require "simplecov"
  SimpleCov.start "rails" do
    enable_coverage :branch
    minimum_coverage line: 70, branch: 50
    add_filter "/test/"
    add_filter "/config/"
    add_filter "/db/"
  end
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Tests always run in English regardless of the configured default locale
    setup { I18n.locale = :en }

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

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
