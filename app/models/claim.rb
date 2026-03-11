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

  validates :canonical_text, :canonical_fingerprint, presence: true
  validates :canonical_fingerprint, uniqueness: true
end
