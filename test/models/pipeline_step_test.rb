require "test_helper"

class PipelineStepTest < ActiveSupport::TestCase
  test "validates presence of name" do
    article = Article.create!(url: "https://ps.com/1", normalized_url: "https://ps.com/1", host: "ps.com")
    inv = Investigation.create!(submitted_url: "https://ps.com/1", normalized_url: "https://ps.com/1", root_article: article)
    step = PipelineStep.new(investigation: inv)
    assert_not step.valid?
    assert_includes step.errors[:name], "can't be blank"
  end

  test "status defaults to queued" do
    article = Article.create!(url: "https://ps2.com/1", normalized_url: "https://ps2.com/1", host: "ps2.com")
    inv = Investigation.create!(submitted_url: "https://ps2.com/1", normalized_url: "https://ps2.com/1", root_article: article)
    step = PipelineStep.create!(investigation: inv, name: "test_step")
    assert step.queued?
  end

  test "status transitions" do
    article = Article.create!(url: "https://ps3.com/1", normalized_url: "https://ps3.com/1", host: "ps3.com")
    inv = Investigation.create!(submitted_url: "https://ps3.com/1", normalized_url: "https://ps3.com/1", root_article: article)
    step = PipelineStep.create!(investigation: inv, name: "lifecycle")

    step.update!(status: :running, started_at: Time.current)
    assert step.running?

    step.update!(status: :completed, finished_at: Time.current)
    assert step.completed?
  end
end
