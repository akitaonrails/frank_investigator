class EvidenceItem < ApplicationRecord
  enum :source_type, {
    article: "article",
    transcript: "transcript",
    scientific_paper: "scientific_paper",
    government_record: "government_record",
    court_record: "court_record",
    company_filing: "company_filing",
    press_release: "press_release",
    dataset: "dataset"
  }, default: :article, validate: true

  enum :stance, {
    unknown: "unknown",
    supports: "supports",
    disputes: "disputes",
    contextualizes: "contextualizes"
  }, default: :unknown, validate: true, prefix: true

  belongs_to :claim_assessment
  belongs_to :article, optional: true

  validates :source_url, presence: true
end
