class Claim < ApplicationRecord
  enum :claim_kind, {
    statement: "statement",
    causality: "causality",
    quantity: "quantity",
    attribution: "attribution",
    prediction: "prediction"
  }, default: :statement, validate: true

  enum :checkability_status, {
    pending: "pending",
    checkable: "checkable",
    ambiguous: "ambiguous",
    not_checkable: "not_checkable"
  }, default: :pending, validate: true

  has_many :article_claims, dependent: :destroy
  has_many :articles, through: :article_claims
  has_many :claim_assessments, dependent: :destroy

  # Claim mutation tracking: variant claims link to a canonical parent
  belongs_to :canonical_parent, class_name: "Claim", optional: true
  has_many :variants, class_name: "Claim", foreign_key: :canonical_parent_id, inverse_of: :canonical_parent, dependent: :nullify

  validates :canonical_text, :canonical_fingerprint, presence: true
  validates :canonical_fingerprint, uniqueness: true

  # Check if this claim or any of its variants has been previously assessed
  def prior_variant_assessment
    return nil unless canonical_parent_id.present?

    # Check parent's assessments
    parent_assessment = canonical_parent.claim_assessments
      .where.not(verdict: "pending")
      .order(confidence_score: :desc)
      .first
    return parent_assessment if parent_assessment

    # Check sibling variants' assessments
    canonical_parent.variants
      .where.not(id: id)
      .joins(:claim_assessments)
      .merge(ClaimAssessment.where.not(verdict: "pending"))
      .first
      &.claim_assessments
      &.where&.not(verdict: "pending")
      &.order(confidence_score: :desc)
      &.first
  end
end
