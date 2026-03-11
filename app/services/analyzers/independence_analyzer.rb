module Analyzers
  class IndependenceAnalyzer
    Result = Struct.new(
      :independent_groups_count,
      :ownership_clusters,
      :syndication_detected,
      :press_release_propagation,
      :independence_score,
      :penalties,
      keyword_init: true
    )

    SYNDICATION_SIMILARITY_THRESHOLD = 0.80
    MIN_BODY_LENGTH = 100

    def self.call(articles:)
      new(articles:).call
    end

    def initialize(articles:)
      @articles = articles.select { |a| a.body_text.present? && a.body_text.length >= MIN_BODY_LENGTH }
    end

    def call
      clusters = ownership_clusters
      syndication = detect_syndication
      press_propagation = detect_press_release_propagation
      penalties = compute_penalties(clusters, syndication, press_propagation)
      independent_count = count_truly_independent(clusters)

      Result.new(
        independent_groups_count: independent_count,
        ownership_clusters: clusters,
        syndication_detected: syndication.any?,
        press_release_propagation: press_propagation.any?,
        independence_score: compute_score(independent_count, penalties),
        penalties:
      )
    end

    private

    def ownership_clusters
      @ownership_clusters ||= begin
        clusters = {}
        @articles.each do |article|
          owner = MediaOwnershipGroup.group_for_host(article.host)
          key = owner&.name || article.independence_group || article.host
          clusters[key] ||= []
          clusters[key] << article
        end
        clusters
      end
    end

    def detect_syndication
      pairs = []
      bodies = @articles.map { |a| [a, tokenize(a.body_text)] }

      bodies.combination(2).each do |(art_a, tokens_a), (art_b, tokens_b)|
        next if tokens_a.empty? || tokens_b.empty?

        similarity = jaccard_similarity(tokens_a, tokens_b)
        if similarity >= SYNDICATION_SIMILARITY_THRESHOLD
          pairs << { articles: [art_a.id, art_b.id], similarity: similarity.round(3) }
        end
      end

      pairs
    end

    def detect_press_release_propagation
      press_releases = @articles.select { |a| a.source_kind == "press_release" }
      return [] if press_releases.empty?

      propagations = []
      news_articles = @articles.select { |a| a.source_kind == "news_article" }

      press_releases.each do |pr|
        pr_tokens = tokenize(pr.body_text)
        next if pr_tokens.empty?

        news_articles.each do |news|
          news_tokens = tokenize(news.body_text)
          next if news_tokens.empty?

          overlap = jaccard_similarity(pr_tokens, news_tokens)
          if overlap >= 0.45
            propagations << {
              press_release_id: pr.id,
              news_article_id: news.id,
              overlap: overlap.round(3)
            }
          end
        end
      end

      propagations
    end

    def count_truly_independent(clusters)
      # Same-owner clusters count as one source, not many
      clusters.keys.count
    end

    def compute_penalties(clusters, syndication, press_propagation)
      penalties = []

      # Penalty if all evidence comes from one ownership group
      if clusters.length == 1 && @articles.length > 1
        penalties << { type: "single_ownership_cluster", severity: 0.3, description: "All evidence comes from one media group" }
      end

      # Penalty for syndicated content masquerading as independent
      if syndication.any?
        penalties << { type: "syndication_detected", severity: 0.2, description: "#{syndication.length} article pair(s) appear to be syndicated copies" }
      end

      # Penalty for press release propagation
      if press_propagation.any?
        penalties << { type: "press_release_propagation", severity: 0.15, description: "#{press_propagation.length} article(s) appear derived from press releases" }
      end

      penalties
    end

    def compute_score(independent_count, penalties)
      base = [independent_count * 0.28, 1.0].min
      total_penalty = penalties.sum { |p| p[:severity] }
      [base - total_penalty, 0.05].max.round(2)
    end

    def tokenize(text)
      TextAnalysis.tokenize(text)
    end

    def jaccard_similarity(set_a, set_b)
      TextAnalysis.jaccard_similarity(set_a, set_b)
    end
  end
end
