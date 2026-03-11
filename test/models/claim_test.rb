require "test_helper"

class ClaimTest < ActiveSupport::TestCase
  test "validates presence of canonical_text and fingerprint" do
    claim = Claim.new
    assert_not claim.valid?
    assert_includes claim.errors[:canonical_text], "can't be blank"
    assert_includes claim.errors[:canonical_fingerprint], "can't be blank"
  end

  test "validates uniqueness of canonical_fingerprint" do
    Claim.create!(canonical_text: "A", canonical_fingerprint: "fp_unique")
    dup = Claim.new(canonical_text: "B", canonical_fingerprint: "fp_unique")
    assert_not dup.valid?
    assert_includes dup.errors[:canonical_fingerprint], "has already been taken"
  end

  test "claim_kind defaults to statement" do
    claim = Claim.create!(canonical_text: "Test", canonical_fingerprint: "test_kind")
    assert claim.statement?
  end

  test "checkability_status defaults to pending" do
    claim = Claim.create!(canonical_text: "Test", canonical_fingerprint: "test_check")
    assert claim.pending?
  end

  test "checkable? and not_checkable? predicates work" do
    checkable = Claim.new(checkability_status: :checkable)
    assert checkable.checkable?
    assert_not checkable.not_checkable?

    not_checkable = Claim.new(checkability_status: :not_checkable)
    assert not_checkable.not_checkable?
  end
end
