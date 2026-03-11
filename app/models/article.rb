class Article < ApplicationRecord
  enum :fetch_status, {
    pending: "pending",
    fetched: "fetched",
    failed: "failed"
  }, default: :pending, validate: true

  enum :source_kind, {
    unknown: "unknown",
    news_article: "news_article",
    government_record: "government_record",
    scientific_paper: "scientific_paper",
    company_filing: "company_filing",
    press_release: "press_release",
    reference: "reference",
    social_post: "social_post"
  }, default: :unknown, validate: true, prefix: true

  enum :authority_tier, {
    unknown: "unknown",
    low: "low",
    secondary: "secondary",
    primary: "primary"
  }, default: :unknown, validate: true, prefix: true

  has_many :article_claims, dependent: :destroy
  has_many :claims, through: :article_claims
  has_many :sourced_links, class_name: "ArticleLink", foreign_key: :source_article_id, inverse_of: :source_article, dependent: :destroy
  has_many :targeted_links, class_name: "ArticleLink", foreign_key: :target_article_id, inverse_of: :target_article, dependent: :destroy
  has_many :evidence_items, dependent: :nullify

  scope :fetched, -> { where(fetch_status: "fetched") }
  scope :authoritative_first, -> { order(authority_score: :desc, fetched_at: :desc) }

  validates :url, :normalized_url, :host, presence: true

  def primary_source?
    authority_tier_primary?
  end
end
