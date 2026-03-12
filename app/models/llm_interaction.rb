class LlmInteraction < ApplicationRecord
  belongs_to :investigation
  belongs_to :claim_assessment, optional: true

  enum :interaction_type, {
    assessment: "assessment",
    claim_decomposition: "claim_decomposition",
    query_generation: "query_generation",
    contradiction_analysis: "contradiction_analysis",
    headline_analysis: "headline_analysis",
    rhetorical_analysis: "rhetorical_analysis"
  }, default: :assessment, validate: true

  enum :status, {
    pending: "pending",
    completed: "completed",
    failed: "failed",
    cached: "cached"
  }, default: :pending, validate: true

  validates :model_id, :prompt_text, presence: true

  scope :for_model, ->(model_id) { where(model_id:) }
  scope :successful, -> { where(status: "completed") }
  scope :recent, -> { order(created_at: :desc) }

  def self.find_cached(evidence_packet_fingerprint:, model_id:)
    where(evidence_packet_fingerprint:, model_id:, status: "completed")
      .order(created_at: :desc)
      .first
  end

  def total_tokens
    (prompt_tokens || 0) + (completion_tokens || 0)
  end
end
