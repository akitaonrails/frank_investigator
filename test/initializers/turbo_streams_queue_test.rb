require "test_helper"

class TurboStreamsQueueTest < ActiveSupport::TestCase
  test "routes Turbo Streams broadcasts to the realtime queue" do
    # Resolving queue_name handles the Proc that ActiveJob stores when
    # queue_as receives a lambda or block.
    queue = Turbo::Streams::BroadcastStreamJob.new.queue_name

    assert_equal "realtime", queue
  end
end
