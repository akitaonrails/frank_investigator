require "digest"

module Investigations
  # Immutable operator decision record.  It deliberately contains data only;
  # execution is still owned by SubmitGroup's locked write path.
  class RepairProjection
    attr_reader :decision_at, :allowlist, :preflight_fingerprint, :input_digest, :action_digest, :plan, :mode

    def initialize(decision_at:, allowlist:, preflight_fingerprint:, planning_input:, plan:, mode: :repair)
      @decision_at = decision_at.utc.round(6).dup.freeze
      @allowlist = deep_freeze(allowlist)
      @mode = mode.to_sym.freeze
      @preflight_fingerprint = preflight_fingerprint.dup.freeze
      @input_digest = Digest::SHA256.hexdigest(canonical(planning_input).to_json).freeze
      @plan = deep_freeze(plan)
      @action_digest = Digest::SHA256.hexdigest(canonical(decision_at: @decision_at, allowlist:, preflight_fingerprint:, input_digest: @input_digest,
        actions: @plan.fetch(:actions)).to_json).freeze
      freeze
    end

    def [](key) = to_h[key]
    def to_h = deep_freeze(plan.merge(decision_at: decision_at.iso8601(6), allowlist:, mode:, preflight_fingerprint:, input_digest:, action_digest:))
    def as_json(*) = to_h
    def to_json(*) = to_h.to_json

    private

    def canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |key| [ key, canonical(value.key?(key) ? value[key] : value[key.to_sym]) ] }
      when Array then value.map { |item| canonical(item) }
      when Time then value.utc.iso8601(6)
      else value
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      when String, Time then value.freeze
      end
      value.freeze
    end
  end
end
