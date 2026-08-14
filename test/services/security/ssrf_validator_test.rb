require "test_helper"

class Security::SsrfValidatorTest < ActiveSupport::TestCase
  test "allows public URLs" do
    assert Security::SsrfValidator.safe?("https://www.example.com/page")
  end

  test "blocks localhost" do
    assert_raises(Security::SsrfValidator::SsrfError) do
      Security::SsrfValidator.validate!("https://localhost/admin")
    end
  end

  test "blocks hostnames that resolve to loopback addresses" do
    DnsStubs.with_addresses("LOOPBACK.example", [ "127.0.0.1" ]) do
      assert_raises(Security::SsrfValidator::SsrfError) do
        Security::SsrfValidator.validate!("https://loopback.example/admin")
      end
    end
  end

  test "blocks hostnames that resolve to private addresses" do
    DnsStubs.with_addresses("private.example", [ "10.0.0.1" ]) do
      assert_raises(Security::SsrfValidator::SsrfError) do
        Security::SsrfValidator.validate!("https://private.example/admin")
      end
    end
  end

  test "blocks hostnames that resolve to link-local addresses" do
    DnsStubs.with_addresses("link-local.example", [ "169.254.169.254" ]) do
      assert_raises(Security::SsrfValidator::SsrfError) do
        Security::SsrfValidator.validate!("https://link-local.example/latest/meta-data/")
      end
    end
  end

  test "blocks numeric IP addresses" do
    assert_raises(Security::SsrfValidator::SsrfError) do
      Security::SsrfValidator.validate!("https://192.168.1.1/secret")
    end
  end

  test "blocks metadata endpoint" do
    assert_raises(Security::SsrfValidator::SsrfError) do
      Security::SsrfValidator.validate!("http://metadata.google.internal/computeMetadata/v1/")
    end
  end

  test "blocks 169.254 link-local range" do
    assert_raises(Security::SsrfValidator::SsrfError) do
      Security::SsrfValidator.validate!("http://169.254.169.254/latest/meta-data/")
    end
  end

  test "blocks non-HTTP schemes" do
    assert_raises(Security::SsrfValidator::SsrfError) do
      Security::SsrfValidator.validate!("ftp://example.com/file")
    end
  end

  test "safe? returns false for blocked URLs" do
    refute Security::SsrfValidator.safe?("https://localhost/admin")
    refute Security::SsrfValidator.safe?("https://10.0.0.1/internal")
  end
end
