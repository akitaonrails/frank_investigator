class InvestigationGroupEvidenceSource < ApplicationRecord
  enum :status, { pending: "pending", fetching: "fetching", ready: "ready", rejected: "rejected", failed: "failed" }, default: :pending, validate: true

  belongs_to :investigation_group
  belongs_to :article

  validates :submitted_url, presence: true
  validates :article_id, uniqueness: { scope: :investigation_group_id }

  def reset_fetch_failure!
    Investigations::EvidenceFetchLease.reset!(self)
  end

  alias_method :reset_for_refresh!, :reset_fetch_failure!
end
