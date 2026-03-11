module Analyzers
  class AuthorityRetrievalDispatcher
    RetrievalResult = Struct.new(:query, :articles_found, keyword_init: true)

    MAX_QUERIES_PER_CLAIM = 5

    def self.call(investigation:, claim:, max_queries: MAX_QUERIES_PER_CLAIM)
      new(investigation:, claim:, max_queries:).call
    end

    def initialize(investigation:, claim:, max_queries:)
      @investigation = investigation
      @claim = claim
      @max_queries = max_queries
    end

    def call
      queries = AuthorityQueryGenerator.call(claim: @claim).first(@max_queries)
      return [] if queries.empty?

      queries.filter_map do |query|
        articles = find_or_create_authority_articles(query)
        next if articles.empty?

        link_articles_to_claim(articles)
        RetrievalResult.new(query:, articles_found: articles)
      end
    end

    private

    def find_or_create_authority_articles(query)
      existing = Article.where(host: query.suggested_hosts).fetched
        .where("body_text LIKE ?", "%#{sanitize_for_like(query.query_text.truncate(60))}%")
        .limit(3)
        .to_a

      return existing if existing.any?

      query.suggested_hosts.filter_map do |host|
        Article.find_by(host:, fetch_status: "fetched")
      end.first(2)
    end

    def link_articles_to_claim(articles)
      articles.each do |article|
        ArticleClaim.find_or_create_by!(
          article:,
          claim: @claim,
          role: :linked_source
        ) do |ac|
          ac.surface_text = @claim.canonical_text.truncate(500)
          ac.stance = :cites
          ac.importance_score = 0.6
        end
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end

    def sanitize_for_like(text)
      text.gsub(/[%_\\]/) { |m| "\\#{m}" }
    end
  end
end
