class Investigation < ApplicationRecord
  REQUIRED_STEPS = %w[fetch_root_article extract_claims analyze_headline assess_claims expand_linked_articles_root].freeze

  broadcasts_refreshes

  enum :status, {
    queued: "queued",
    processing: "processing",
    completed: "completed",
    failed: "failed"
  }, default: :queued, validate: true

  enum :checkability_status, {
    pending: "pending",
    checkable: "checkable",
    partially_checkable: "partially_checkable",
    not_checkable: "not_checkable"
  }, default: :pending, validate: true

  belongs_to :root_article, class_name: "Article", optional: true

  has_many :pipeline_steps, dependent: :destroy
  has_many :claim_assessments, dependent: :destroy
  has_many :claims, through: :claim_assessments

  validates :submitted_url, :normalized_url, presence: true
  validates :normalized_url, uniqueness: true

  def status_badge
    I18n.t("enums.pipeline_status.#{status}", default: status.tr("_", " "))
  end
end
