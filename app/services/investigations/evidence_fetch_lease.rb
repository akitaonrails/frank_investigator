module Investigations
  class EvidenceFetchLease
    LEASE_FOR = 5.minutes
    DELIVERY_LEASE_FOR = 2.minutes
    MAX_ATTEMPTS = 4

    def self.claim!(source)
      source.with_lock do
        source.reload
        return if source.ready? || source.rejected? || source.failed?
        return if source.fetching? && source.fetch_lease_expires_at&.future?
        return if source.fetch_retry_due_at&.future?

        token = SecureRandom.uuid
        source.fetch_attempts_generation ||= SecureRandom.uuid
        source.update!(status: :fetching, fetch_token: token, fetch_lease_expires_at: LEASE_FOR.from_now,
          fetch_retry_due_at: nil, fetch_delivery_token: nil, fetch_delivery_expires_at: nil,
          attempts_count: source.attempts_count + 1, last_error_class: nil, last_error_message: nil)
        token
      end
    end

    def self.retry_delay(attempts)
      (attempts**2).minutes
    end

    def self.fail_transient!(source, token, error)
      source.with_lock do
        source.reload
        return false unless active?(source, token)
        if source.attempts_count >= MAX_ATTEMPTS
          source.update!(status: :failed, terminal_at: Time.current, fetch_token: nil, fetch_lease_expires_at: nil,
            last_error_class: error.class.name, last_error_message: error.message)
        else
          source.update!(status: :pending, fetch_token: nil, fetch_lease_expires_at: nil,
            fetch_retry_due_at: retry_delay(source.attempts_count).from_now,
            last_error_class: error.class.name, last_error_message: error.message)
        end
        true
      end
    end

    def self.expire!(source)
      source.with_lock do
        source.reload
        return false unless source.fetching? && source.fetch_lease_expires_at&.past?
        if source.attempts_count >= MAX_ATTEMPTS
          source.update!(status: :failed, terminal_at: Time.current, fetch_token: nil, fetch_lease_expires_at: nil,
            fetch_retry_due_at: nil, last_error_class: "LeaseExpired", last_error_message: "fetch lease expired after #{source.attempts_count} attempts")
        else
          source.update!(status: :pending, fetch_token: nil, fetch_lease_expires_at: nil, fetch_retry_due_at: Time.current)
        end
        true
      end
    end

    # eligible_at is the operator's immutable decision boundary; now is when
    # the durable lease is actually issued, so delayed applies never mint an
    # already-expired token.
    def self.claim_delivery!(source, eligible_at: Time.current, now: nil)
      source.with_lock do
        source.reload
        issued_at = now || Time.current
        return unless delivery_eligible?(source, eligible_at:)
        token = SecureRandom.uuid
        source.update!(fetch_delivery_token: token, fetch_delivery_expires_at: issued_at + DELIVERY_LEASE_FOR)
        token
      end
    end

    # Read-only companion to claim_delivery!.  Plans must use precisely the
    # same gate without manufacturing a delivery token.
    def self.delivery_eligible?(source, eligible_at: Time.current, at: nil)
      eligible_at = at if at
      source.pending? && (source.fetch_retry_due_at.nil? || source.fetch_retry_due_at <= eligible_at) &&
        !(source.fetch_delivery_expires_at && source.fetch_delivery_expires_at > eligible_at)
    end

    def self.reset_required?(source, at: Time.current)
      source.failed? || source.rejected? || (source.fetching? && (!source.fetch_lease_expires_at || source.fetch_lease_expires_at <= at))
    end

    # Attaching evidence must not erase an operator/backoff decision. Only an
    # old pending row with no schedule receives the normal immediate due time.
    def self.schedule!(source, at: Time.current)
      source.with_lock do
        source.reload
        source.update!(fetch_retry_due_at: at) if source.pending? && source.fetch_retry_due_at.nil?
      end
    end

    def self.release_delivery!(source, token)
      InvestigationGroupEvidenceSource.where(id: source.id, fetch_delivery_token: token).update_all(fetch_delivery_token: nil, fetch_delivery_expires_at: nil)
    end

    def self.reset!(source, at: Time.current)
      source.with_lock do
        was_ready = source.ready?
        source.update!(status: :pending, attempts_count: 0, fetch_attempts_generation: SecureRandom.uuid,
          terminal_at: nil, fetch_token: nil, fetch_lease_expires_at: nil, fetch_retry_due_at: at,
          fetch_delivery_token: nil, fetch_delivery_expires_at: nil, last_error_class: nil,
          last_error_message: nil, ready_at: nil, content_fingerprint: (source.content_fingerprint if was_ready))
      end
    end

    def self.active?(source, token)
      source.fetch_token == token && source.fetch_lease_expires_at&.future?
    end
  end
end
