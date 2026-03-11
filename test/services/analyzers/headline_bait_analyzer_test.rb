require "test_helper"

class Analyzers::HeadlineBaitAnalyzerTest < ActiveSupport::TestCase
  test "low score for matching headline and body" do
    result = Analyzers::HeadlineBaitAnalyzer.call(
      title: "Government passes new tax law",
      body_text: "The government passes a new tax law affecting millions of citizens."
    )
    assert_operator result.score, :<, 40
  end

  test "high score for sensational headline not supported by body" do
    result = Analyzers::HeadlineBaitAnalyzer.call(
      title: "SHOCKING bombshell exposed in government scandal destroys trust",
      body_text: "The committee held a routine meeting to discuss budget allocations."
    )
    assert_operator result.score, :>, 50
  end

  test "zero score for blank title" do
    result = Analyzers::HeadlineBaitAnalyzer.call(title: "", body_text: "Some body text.")
    assert_equal 0, result.score
  end

  test "returns reason string" do
    result = Analyzers::HeadlineBaitAnalyzer.call(title: "Test", body_text: "Test content")
    assert result.reason.is_a?(String)
    assert result.reason.length > 0
  end
end
