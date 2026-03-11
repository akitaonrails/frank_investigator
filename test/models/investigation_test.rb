require "test_helper"

class InvestigationTest < ActiveSupport::TestCase
  test "validates presence of submitted_url and normalized_url" do
    inv = Investigation.new
    assert_not inv.valid?
    assert_includes inv.errors[:submitted_url], "can't be blank"
    assert_includes inv.errors[:normalized_url], "can't be blank"
  end

  test "validates uniqueness of normalized_url" do
    Investigation.create!(submitted_url: "https://example.com/a", normalized_url: "https://example.com/a")
    dup = Investigation.new(submitted_url: "https://example.com/b", normalized_url: "https://example.com/a")
    assert_not dup.valid?
    assert_includes dup.errors[:normalized_url], "has already been taken"
  end

  test "status enum defaults to queued" do
    inv = Investigation.create!(submitted_url: "https://example.com/enum", normalized_url: "https://example.com/enum")
    assert inv.queued?
  end

  test "status_badge formats status" do
    inv = Investigation.new(status: :processing)
    assert_equal "processing", inv.status_badge
  end

  test "REQUIRED_STEPS contains expected pipeline steps" do
    assert_includes Investigation::REQUIRED_STEPS, "fetch_root_article"
    assert_includes Investigation::REQUIRED_STEPS, "assess_claims"
  end
end
