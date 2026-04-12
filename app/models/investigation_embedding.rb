class InvestigationEmbedding < ApplicationRecord
  enum :status, {
    pending: "pending",
    indexed: "indexed",
    failed: "failed"
  }, default: :pending, validate: true

  belongs_to :investigation

  validates :content_digest, :dimensions, :model_id, presence: true
end
