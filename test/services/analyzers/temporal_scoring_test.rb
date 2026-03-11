require "test_helper"

class Analyzers::TemporalScoringTest < ActiveSupport::TestCase
  test "evidence before claim range scores 0.9" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.9, Analyzers::TemporalScoring.score(Date.new(2025, 2, 15), claim_range)
  end

  test "evidence during claim range scores 0.9" do
    claim_range = Date.new(2025, 1, 1)..Date.new(2025, 12, 31)
    assert_equal 0.9, Analyzers::TemporalScoring.score(Date.new(2025, 6, 15), claim_range)
  end

  test "evidence within 30 days after claim range scores 0.5" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.5, Analyzers::TemporalScoring.score(Date.new(2025, 4, 15), claim_range)
  end

  test "evidence far after claim range scores 0.2" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.2, Analyzers::TemporalScoring.score(Date.new(2025, 8, 1), claim_range)
  end

  test "nil evidence date scores 0.15" do
    claim_range = Date.new(2025, 1, 1)..Date.new(2025, 12, 31)
    assert_equal 0.15, Analyzers::TemporalScoring.score(nil, claim_range)
  end

  test "nil claim range scores 0.15" do
    assert_equal 0.15, Analyzers::TemporalScoring.score(Date.new(2025, 6, 1), nil)
  end

  test "accepts datetime as evidence date" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.9, Analyzers::TemporalScoring.score(Time.new(2025, 3, 15, 12, 0, 0), claim_range)
  end

  test "evidence on last day of claim range scores 0.9" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.9, Analyzers::TemporalScoring.score(Date.new(2025, 3, 31), claim_range)
  end

  test "evidence one day after claim range scores 0.5" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.5, Analyzers::TemporalScoring.score(Date.new(2025, 4, 1), claim_range)
  end

  test "evidence exactly 30 days after claim range end scores 0.5" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.5, Analyzers::TemporalScoring.score(Date.new(2025, 4, 30), claim_range)
  end

  test "evidence 31 days after claim range end scores 0.2" do
    claim_range = Date.new(2025, 3, 1)..Date.new(2025, 3, 31)
    assert_equal 0.2, Analyzers::TemporalScoring.score(Date.new(2025, 5, 1), claim_range)
  end
end
