class InvestigationGroup < ApplicationRecord
  belongs_to :main_investigation, class_name: "Investigation", inverse_of: :owned_group
  has_many :investigations, dependent: :nullify
  has_many :evidence_sources, class_name: "InvestigationGroupEvidenceSource", dependent: :destroy

  validates :main_investigation_id, uniqueness: true
end
