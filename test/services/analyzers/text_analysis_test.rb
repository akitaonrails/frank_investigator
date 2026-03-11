require "test_helper"

class Analyzers::TextAnalysisTest < ActiveSupport::TestCase
  test "normalize strips punctuation and lowercases" do
    assert_equal "hello world 123", Analyzers::TextAnalysis.normalize("Hello, World! 123.")
  end

  test "tokenize returns set of significant tokens" do
    tokens = Analyzers::TextAnalysis.tokenize("The quick brown fox jumps over the lazy dog")
    assert_includes tokens, "quick"
    assert_includes tokens, "brown"
    assert_not_includes tokens, "the"
  end

  test "tokenize respects min_length" do
    tokens = Analyzers::TextAnalysis.tokenize("I am ok now", min_length: 3)
    assert_not_includes tokens, "am"
    assert_not_includes tokens, "ok"
    assert_includes tokens, "now"
  end

  test "tokenize can keep stop words" do
    tokens = Analyzers::TextAnalysis.tokenize("the cat is here", remove_stop_words: false)
    assert_includes tokens, "the"
    assert_includes tokens, "cat"
  end

  test "simple_tokens returns array of lowercase alphanumeric words" do
    tokens = Analyzers::TextAnalysis.simple_tokens("Hello World! 123 test")
    assert_equal %w[hello world 123 test], tokens
  end

  test "jaccard_similarity computes correctly" do
    set_a = Set.new(%w[cat dog bird])
    set_b = Set.new(%w[cat fish bird])
    sim = Analyzers::TextAnalysis.jaccard_similarity(set_a, set_b)
    assert_in_delta 0.5, sim, 0.01
  end

  test "jaccard_similarity handles empty sets" do
    assert_equal 0.0, Analyzers::TextAnalysis.jaccard_similarity(Set.new, Set.new)
  end

  test "stop words include English and Portuguese" do
    assert Analyzers::TextAnalysis::STOP_WORDS.include?("the")
    assert Analyzers::TextAnalysis::STOP_WORDS.include?("para")
  end
end
