module Analyzers
  class EvidencePacketBuilder
    Entry = Struct.new(
      :article,
      :stance,
      :relevance_score,
      :authority_score,
      :authority_tier,
      :source_kind,
      :independence_group,
      :headline_divergence,
      keyword_init: true
    )

    def self.call(investigation:, claim:)
      new(investigation:, claim:).call
    end

    def initialize(investigation:, claim:)
      @investigation = investigation
      @claim = claim
    end

    # Discount authority for articles whose headline diverges significantly
    # from their body content. A baiting article is unreliable evidence.
    HEADLINE_DIVERGENCE_AUTHORITY_PENALTY = 0.4

    def call
      supporting_articles.map do |article|
        relationship = EvidenceRelationshipAnalyzer.call(claim: @claim, article:, investigation: @investigation)
        divergence = headline_divergence_for(article)
        authority = apply_headline_penalty(article.authority_score.to_f, divergence)

        Entry.new(
          article:,
          stance: relationship.stance,
          relevance_score: relationship.relevance_score,
          authority_score: authority,
          authority_tier: article.authority_tier,
          source_kind: article.source_kind,
          independence_group: article.independence_group.presence || article.host,
          headline_divergence: divergence
        )
      end.select { |entry| entry.relevance_score.positive? }
    end

    private

    def headline_divergence_for(article)
      # Use cached score if available
      return article.headline_divergence_score.to_f if article.headline_divergence_score.present?
      return 0.0 if article.title.blank? || article.body_text.blank?

      result = HeadlineBaitAnalyzer.call(title: article.title, body_text: article.body_text)
      score = result.score / 100.0 # Normalize from 0-100 to 0-1

      # Cache for future use
      article.update_column(:headline_divergence_score, score) if article.persisted?
      score
    end

    def apply_headline_penalty(base_authority, divergence)
      return base_authority if divergence < 0.4

      # Scale penalty: 40% divergence = mild, 80%+ = heavy
      penalty_factor = ((divergence - 0.4) / 0.6) * HEADLINE_DIVERGENCE_AUTHORITY_PENALTY
      [base_authority - penalty_factor, 0.05].max.round(2)
    end

    def supporting_articles
      @claim.articles.fetched.where.not(id: @investigation.root_article_id).distinct.authoritative_first
    end
  end
end
