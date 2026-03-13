class Article < ApplicationRecord
  enum :fetch_status, {
    pending: "pending",
    fetched: "fetched",
    failed: "failed",
    rejected: "rejected"
  }, default: :pending, validate: true

  enum :source_kind, {
    unknown: "unknown",
    news_article: "news_article",
    government_record: "government_record",
    legislative_record: "legislative_record",
    court_record: "court_record",
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

  enum :source_role, {
    unknown: "unknown",
    official_position: "official_position",
    authenticated_legal_text: "authenticated_legal_text",
    neutral_statistics: "neutral_statistics",
    oversight: "oversight",
    research_discovery: "research_discovery",
    news_reporting: "news_reporting"
  }, default: :unknown, validate: true, prefix: true

  has_many :article_claims, dependent: :destroy
  has_many :claims, through: :article_claims
  has_many :sourced_links, class_name: "ArticleLink", foreign_key: :source_article_id, inverse_of: :source_article, dependent: :destroy
  has_many :targeted_links, class_name: "ArticleLink", foreign_key: :target_article_id, inverse_of: :target_article, dependent: :destroy
  has_many :evidence_items, dependent: :nullify

  scope :fetched, -> { where(fetch_status: "fetched") }
  scope :authoritative_first, -> { order(authority_score: :desc, fetched_at: :desc) }

  validates :url, :normalized_url, :host, presence: true
  validates :normalized_url, uniqueness: true

  def primary_source?
    authority_tier_primary?
  end

  def fresh?
    fetched? && fetched_at.present? &&
      fetched_at > Rails.application.config.x.frank_investigator.article_freshness_ttl.seconds.ago
  end

  def evidence_source_type
    case source_kind
    when "government_record" then :government_record
    when "legislative_record" then :government_record
    when "court_record" then :court_record
    when "scientific_paper" then :scientific_paper
    when "company_filing" then :company_filing
    when "press_release" then :press_release
    else
      :article
    end
  end
end
