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
  belongs_to :investigation_group, optional: true
  has_one :owned_group, class_name: "InvestigationGroup", foreign_key: :main_investigation_id, dependent: :destroy, inverse_of: :main_investigation

  # Self-reference: this investigation was auto-submitted by another after
  # cross-reference detected related coverage. Used by RefreshParentEnrichmentJob
  # to feed child analysis back into the parent's event_context and honest_headline.
  belongs_to :auto_submitted_from, class_name: "Investigation", optional: true
  has_many :auto_submitted_children,
           class_name: "Investigation",
           foreign_key: :auto_submitted_from_id,
           dependent: :nullify,
           inverse_of: :auto_submitted_from

  has_many :pipeline_steps, dependent: :destroy
  has_many :claim_assessments, dependent: :destroy
  has_many :claims, through: :claim_assessments
  has_one :investigation_embedding, dependent: :destroy

  enum :group_membership_kind, { manual: "manual", auto: "auto" }, prefix: true, validate: { allow_nil: true }

  validates :submitted_url, :normalized_url, presence: true
  validates :normalized_url, uniqueness: true
  validate :group_membership_is_complete

  before_create :generate_slug

  def to_param
    slug
  end

  def status_badge
    I18n.t("enums.pipeline_status.#{status}", default: status.tr("_", " "))
  end

  private

  def group_membership_is_complete
    if investigation_group_id.present? && group_membership_kind.blank?
      errors.add(:group_membership_kind, "is required for grouped investigations")
    elsif investigation_group_id.blank? && group_membership_kind.present?
      errors.add(:group_membership_kind, "requires a group")
    end
  end

  def generate_slug
    self.slug ||= SecureRandom.hex(5)
  end
end
