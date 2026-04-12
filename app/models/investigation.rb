class Investigation < ApplicationRecord
  REQUIRED_STEPS = %w[
    fetch_root_article extract_claims analyze_headline assess_claims expand_linked_articles_root
    detect_source_misrepresentation detect_temporal_manipulation detect_statistical_deception
    detect_selective_quotation detect_authority_laundering
    analyze_rhetorical_structure analyze_contextual_gaps detect_coordinated_narrative
    score_emotional_manipulation generate_summary
  ].freeze

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
  has_one :investigation_embedding, dependent: :destroy

  validates :submitted_url, :normalized_url, presence: true
  validates :normalized_url, uniqueness: true

  before_create :generate_slug

  def to_param
    slug
  end

  def status_badge
    I18n.t("enums.pipeline_status.#{status}", default: status.tr("_", " "))
  end

  private

  def generate_slug
    self.slug ||= SecureRandom.hex(5)
  end
end
