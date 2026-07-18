module Analyzers
  class ActiveEvidenceRetriever
    MAX_FETCHES_PER_CLAIM = 3

    def self.call(investigation:, claim:)
      new(investigation:, claim:).call
    end

    def initialize(investigation:, claim:)
      @investigation = investigation
      @claim = claim
    end

    def call
      root_host = @investigation.root_article&.host
      queries = build_search_queries
      return [] if queries.empty?

      fetched = 0
      results = []
      seen_hosts = Set.new([ root_host ].compact)
      seen_urls = existing_linked_urls

      queries.each do |query_text|
        break if fetched >= MAX_FETCHES_PER_CLAIM

        search_results = Fetchers::WebSearcher.call(query: query_text)
        search_results.each do |sr|
          break if fetched >= MAX_FETCHES_PER_CLAIM

          normalized = normalize_url(sr.url)
          next unless normalized

          host = begin
            URI.parse(normalized).host
          rescue URI::InvalidURIError
            next
          end

          next if seen_hosts.count { |h| h == host } >= 2  # Max 2 per host
          next if seen_urls.include?(normalized)

          article = fetch_and_persist(normalized, sr.title)
          if article&.fetched?
            fetched += 1
            seen_hosts << host
            seen_urls << normalized
            results << article
            link_to_claim(article)
          end
        end
      end

      results
    end

    private

    def build_search_queries
      llm_queries = LlmSearchQueryGenerator.call(
        claim: @claim,
        root_article_host: @investigation.root_article&.host,
        investigation: @investigation
      )
      authority_queries = AuthorityQueryGenerator.call(claim: @claim)
        .first(2).map(&:query_text)
      (llm_queries + authority_queries).uniq.first(5)
    end

    def existing_linked_urls
      @claim.articles.pluck(:normalized_url).to_set
    end

    def normalize_url(url)
      Investigations::UrlNormalizer.call(url)
    rescue Investigations::UrlNormalizer::InvalidUrlError
      nil
    end

    def fetch_and_persist(normalized_url, title)
      existing = Article.find_by(normalized_url:)
      return existing if existing&.fetched?

      article = Article.find_or_create_by!(normalized_url:) do |a|
        a.url = normalized_url
        a.host = URI.parse(normalized_url).host
        a.fetch_status = :pending
      end
    rescue ActiveRecord::RecordNotUnique
      Article.find_by!(normalized_url:)
    else
      return article if article.fetched?

      begin
        # Bind this fetch attempt to the content we observed before network IO.
        # A concurrent successful fetch advances this generation.
        fetch_generation = article.content_generation
        fetcher = fetcher_class.constantize.new
        snapshot = fetcher.call(normalized_url)
        Articles::PersistFetchedContent.call(
          article:,
          html: snapshot.html,
          fetched_title: snapshot.title,
          current_depth: 1
        )
        article.reload
      rescue StandardError => e
        Rails.logger.warn("Active retrieval fetch failed for #{normalized_url}: #{e.message}")
        mark_failed_if_current_generation(article, fetch_generation)
        nil
      end
    end

    def mark_failed_if_current_generation(article, generation)
      return unless generation

      # CAS prevents an old failed browser request from replacing newer fetched
      # content. Do not lock around the network request or content processing.
      Article.where(id: article.id, content_generation: generation)
        .where.not(fetch_status: :fetched)
        .update_all(fetch_status: :failed)
    end

    def link_to_claim(article)
      ArticleClaim.find_or_create_by!(
        article:,
        claim: @claim,
        role: :linked_source
      ) do |ac|
        ac.surface_text = @claim.canonical_text.truncate(500)
        ac.stance = :cites
        ac.importance_score = 0.7
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def fetcher_class
      Rails.application.config.x.frank_investigator.fetcher_class
    end
  end
end
