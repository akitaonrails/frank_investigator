require "test_helper"

class Claims::DetectSourceCorrectionsJobTest < ActiveSupport::TestCase
  test "calls source correction detector and completes without error" do
    assert_nothing_raised do
      Claims::DetectSourceCorrectionsJob.perform_now
    end
  end
end
