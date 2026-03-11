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
      keyword_init: true
    )

    def self.call(investigation:, claim:)
      new(investigation:, claim:).call
    end

    def initialize(investigation:, claim:)
      @investigation = investigation
      @claim = claim
    end

    def call
      supporting_articles.map do |article|
        relationship = EvidenceRelationshipAnalyzer.call(claim: @claim, article:)
        Entry.new(
          article:,
          stance: relationship.stance,
          relevance_score: relationship.relevance_score,
          authority_score: article.authority_score.to_f,
          authority_tier: article.authority_tier,
          source_kind: article.source_kind,
          independence_group: article.independence_group.presence || article.host
        )
      end.select { |entry| entry.relevance_score.positive? }
    end

    private

    def supporting_articles
      @claim.articles.fetched.where.not(id: @investigation.root_article_id).distinct.authoritative_first
    end
  end
end
