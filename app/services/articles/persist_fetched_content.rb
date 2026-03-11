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
      connector_result = Sources::ConnectorRouter.call(
        url: @article.normalized_url,
        host: @article.host,
        title: extracted.title || @fetched_title,
        html: @html,
        source_kind: source_metadata.source_kind,
        authority_tier: source_metadata.authority_tier,
        authority_score: source_metadata.authority_score
      )

      ApplicationRecord.transaction do
        @article.update!(
          title: extracted.title.presence || @fetched_title,
          body_text: extracted.body_text,
          excerpt: extracted.excerpt,
          fetch_status: :fetched,
          published_at: connector_result.published_at || @article.published_at,
          fetched_at: Time.current,
          content_fingerprint: Digest::SHA256.hexdigest(extracted.body_text.to_s),
          main_content_path: extracted.main_content_path,
          source_kind: connector_result.source_kind || source_metadata.source_kind,
          authority_tier: connector_result.authority_tier || source_metadata.authority_tier,
          authority_score: connector_result.authority_score || source_metadata.authority_score,
          independence_group: source_metadata.independence_group,
          source_role: source_metadata.source_role || :unknown,
          metadata_json: connector_result.metadata_json || {}
        )

        upsert_links!(extracted.links)
        store_html_snapshot!
      end

      extracted
    end

    private

    def store_html_snapshot!
      HtmlSnapshot.store!(article: @article, html: @html, url: @article.normalized_url)
    rescue => e
      Rails.logger.warn("Failed to store HTML snapshot for #{@article.normalized_url}: #{e.message}")
    end

    def upsert_links!(links)
      links.each do |link|
        target_article = find_or_create_target_article!(link)
        upsert_article_link!(link, target_article)
      end
    end

    def find_or_create_target_article!(link)
      Article.find_or_create_by!(normalized_url: link[:href]) do |record|
        target_source = Sources::AuthorityClassifier.call(url: link[:href], host: URI.parse(link[:href]).host)
        record.url = link[:href]
        record.host = URI.parse(link[:href]).host
        record.source_kind = target_source.source_kind
        record.authority_tier = target_source.authority_tier
        record.authority_score = target_source.authority_score
        record.independence_group = target_source.independence_group
        record.source_role = target_source.source_role || :unknown
      end
    rescue ActiveRecord::RecordNotUnique
      Article.find_by!(normalized_url: link[:href])
    end

    def upsert_article_link!(link, target_article)
      ArticleLink.find_or_create_by!(source_article: @article, href: link[:href]) do |record|
        record.target_article = target_article
        record.anchor_text = link[:anchor_text]
        record.context_excerpt = link[:context_excerpt]
        record.position = link[:position]
        record.depth = @current_depth + 1
      end
    rescue ActiveRecord::RecordNotUnique
      ArticleLink.find_by!(source_article: @article, href: link[:href])
    end
  end
end
