require "test_helper"

class Analyzers::CheckabilityClassifierTest < ActiveSupport::TestCase
  test "classifies questions as ambiguous" do
    assert_equal :ambiguous, Analyzers::CheckabilityClassifier.call("Is the economy improving?")
  end

  test "classifies blank text as ambiguous" do
    assert_equal :ambiguous, Analyzers::CheckabilityClassifier.call("")
  end

  test "classifies opinions as not_checkable" do
    assert_equal :not_checkable, Analyzers::CheckabilityClassifier.call("I think this is the best policy ever proposed.")
  end

  test "classifies statements with numbers as checkable" do
    assert_equal :checkable, Analyzers::CheckabilityClassifier.call("Inflation rose to 8 percent in March.")
  end

  test "classifies statements with named entities as checkable" do
    assert_equal :checkable, Analyzers::CheckabilityClassifier.call("President Biden announced the new measure.")
  end

  test "classifies attributions as checkable" do
    assert_equal :checkable, Analyzers::CheckabilityClassifier.call("The minister said the project is on schedule.")
  end

  test "classifies vague statements as ambiguous" do
    assert_equal :ambiguous, Analyzers::CheckabilityClassifier.call("things are changing in the world today")
  end
end
