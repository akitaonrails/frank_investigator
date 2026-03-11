module Articles
  class PersistFetchedContent
    def self.call(article:, html:, fetched_title:, current_depth:)
      new(article:, html:, fetched_title:, current_depth:).call
    end

    def initialize(article:, html:, fetched_title:, current_depth:)
      @article = article
      @html = html
      @fetched_title = fetched_title
      @current_depth = current_depth
    end

    def call
      extracted = Parsing::MainContentExtractor.call(html: @html, url: @article.normalized_url)
      source_metadata = Sources::AuthorityClassifier.call(url: @article.normalized_url, host: @article.host, title: extracted.title || @fetched_title)

      ApplicationRecord.transaction do
        @article.update!(
          title: extracted.title.presence || @fetched_title,
          body_text: extracted.body_text,
          excerpt: extracted.excerpt,
          fetch_status: :fetched,
          fetched_at: Time.current,
          content_fingerprint: Digest::SHA256.hexdigest(extracted.body_text.to_s),
          main_content_path: extracted.main_content_path,
          source_kind: source_metadata.source_kind,
          authority_tier: source_metadata.authority_tier,
          authority_score: source_metadata.authority_score,
          independence_group: source_metadata.independence_group
        )

        upsert_links!(extracted.links)
      end

      extracted
    end

    private

    def upsert_links!(links)
      links.each do |link|
        target_article = Article.find_or_create_by!(normalized_url: link[:href]) do |record|
          record.url = link[:href]
          record.host = URI.parse(link[:href]).host
        end

        ArticleLink.find_or_initialize_by(source_article: @article, href: link[:href]).tap do |record|
          record.target_article = target_article
          record.anchor_text = link[:anchor_text]
          record.context_excerpt = link[:context_excerpt]
          record.position = link[:position]
          record.depth = @current_depth + 1
          record.save!
        end
      end
    end
  end
end
