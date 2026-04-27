require "test_helper"

class Monitoring::SmokeCheckTest < ActiveSupport::TestCase
  test "run_all returns results for all checks" do
    results = Monitoring::SmokeCheck.run_all
    assert_equal 4, results.size
    results.each do |result|
      assert_includes %i[ok fail degraded skip error], result.status
      assert result.check_name.present?
      assert result.message.present?
    end
  end

  test "content_extraction_shape check passes with valid HTML" do
    results = Monitoring::SmokeCheck.run_all
    extraction_result = results.find { |r| r.check_name == "content_extraction_shape" }
    assert_equal :ok, extraction_result.status
  end

  test "llm_availability returns skip when no API key" do
    original = ENV["OPENROUTER_API_KEY"]
    ENV.delete("OPENROUTER_API_KEY")

    results = Monitoring::SmokeCheck.run_all
    llm_result = results.find { |r| r.check_name == "llm_availability" }
    assert_equal :skip, llm_result.status

  ensure
    ENV["OPENROUTER_API_KEY"] = original if original
  end

  test "llm_availability returns ok when API key and models configured" do
    ENV["OPENROUTER_API_KEY"] = "test-key"

    results = Monitoring::SmokeCheck.run_all
    llm_result = results.find { |r| r.check_name == "llm_availability" }
    assert_equal :ok, llm_result.status
    assert_includes llm_result.message, "model(s) configured"

  ensure
    ENV.delete("OPENROUTER_API_KEY")
  end

  test "results include duration_ms" do
    results = Monitoring::SmokeCheck.run_all
    results.each do |result|
      assert_kind_of Integer, result.duration_ms
      assert_operator result.duration_ms, :>=, 0
    end
  end

  test "sqlite_stack reports gem and runtime versions" do
    results = Monitoring::SmokeCheck.run_all
    sqlite_result = results.find { |r| r.check_name == "sqlite_stack" }

    assert_includes %i[ok degraded], sqlite_result.status
    assert_includes sqlite_result.message, "sqlite3 gem"
    assert_includes sqlite_result.message, "SQLite runtime"
  end

  test "smoke check job runs without error" do
    assert_nothing_raised do
      Monitoring::SmokeCheckJob.perform_now
    end
  end
end
