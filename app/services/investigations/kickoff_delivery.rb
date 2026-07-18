module Investigations
  # A delivery lease is deliberately separate from the pipeline state: adapters
  # can lose an enqueue, while a queued investigation must remain recoverable.
  class KickoffDelivery
    LEASE_FOR = 5.minutes

    def self.schedule!(investigation)
      investigation.with_lock do
        schedule_in_transaction!(investigation)
      end
    end

    # Call while the caller's domain transaction owns the investigation. This
    # makes creation/attachment and durable dispatch intent one atomic change.
    def self.schedule_in_transaction!(investigation, now: Time.current)
      investigation.update!(kickoff_due_at: now) if investigation.queued? && investigation.kickoff_due_at.nil?
    end

    def self.claim!(investigation)
      investigation.with_lock do
        investigation.reload
        return unless investigation.status.in?(%w[queued processing]) && investigation.kickoff_due_at && investigation.kickoff_due_at <= Time.current
        return if investigation.kickoff_delivery_expires_at&.future?
        token = SecureRandom.uuid
        investigation.update!(kickoff_delivery_token: token, kickoff_delivery_expires_at: LEASE_FOR.from_now)
        token
      end
    end

    def self.acknowledge!(investigation, token)
      Investigation.where(id: investigation.id, kickoff_delivery_token: token).update_all(kickoff_due_at: nil, kickoff_delivery_token: nil,
        kickoff_delivery_expires_at: nil, kickoff_delivered_at: Time.current)
    end

    def self.release!(investigation, token)
      Investigation.where(id: investigation.id, kickoff_delivery_token: token).update_all(kickoff_delivery_token: nil, kickoff_delivery_expires_at: nil)
    end
  end
end
