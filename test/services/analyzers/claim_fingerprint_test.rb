require "test_helper"

class Analyzers::ClaimFingerprintTest < ActiveSupport::TestCase
  test "generates SHA256 fingerprint from text" do
    fp = Analyzers::ClaimFingerprint.call("Brazil GDP grew 3.1%")

    assert_equal 64, fp.length
    assert_match(/\A[a-f0-9]{64}\z/, fp)
  end

  test "same text produces same fingerprint" do
    fp1 = Analyzers::ClaimFingerprint.call("Brazil GDP grew 3.1%")
    fp2 = Analyzers::ClaimFingerprint.call("Brazil GDP grew 3.1%")

    assert_equal fp1, fp2
  end

  test "normalizes before fingerprinting" do
    fp1 = Analyzers::ClaimFingerprint.call("Brazil GDP grew 3.1%!")
    fp2 = Analyzers::ClaimFingerprint.call("BRAZIL GDP GREW 3.1%!")

    assert_equal fp1, fp2
  end

  test "uses canonical_form when provided" do
    fp_raw = Analyzers::ClaimFingerprint.call("The economy expanded a lot")
    fp_canon = Analyzers::ClaimFingerprint.call("The economy expanded a lot", canonical_form: "GDP grew 3.1%")

    refute_equal fp_raw, fp_canon
    assert_equal fp_canon, Analyzers::ClaimFingerprint.call("doesn't matter", canonical_form: "GDP grew 3.1%")
  end

  test "different text produces different fingerprint" do
    fp1 = Analyzers::ClaimFingerprint.call("Unemployment rose to 5%")
    fp2 = Analyzers::ClaimFingerprint.call("Inflation dropped to 3%")

    refute_equal fp1, fp2
  end
end
