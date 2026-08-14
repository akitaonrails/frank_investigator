require "resolv"

module DnsStubs
  DEFAULT_ADDRESSES = [ "93.184.216.34" ].freeze
  THREAD_KEY = :dns_stubs_addresses

  def self.with_addresses(host, addresses)
    previous_overrides = Thread.current[THREAD_KEY]
    overrides = previous_overrides ? previous_overrides.dup : {}
    overrides[normalize_host(host)] = Array(addresses).map(&:to_s).freeze
    Thread.current[THREAD_KEY] = overrides.freeze

    yield
  ensure
    Thread.current[THREAD_KEY] = previous_overrides
  end

  def self.addresses_for(host)
    Thread.current[THREAD_KEY]&.fetch(normalize_host(host), DEFAULT_ADDRESSES) || DEFAULT_ADDRESSES
  end

  def self.normalize_host(host)
    host.to_s.downcase
  end
  private_class_method :normalize_host

  module ResolvGetaddressesOverride
    def getaddresses(host)
      DnsStubs.addresses_for(host)
    end
  end
end

Resolv.singleton_class.prepend(DnsStubs::ResolvGetaddressesOverride)
