module Articles
  class PersistFetchedContent
    class StaleGeneration < StandardError; end
    Staged = Data.define(:extracted, :connector_result, :source_metadata, :html, :fetched_title, :current_depth, :rejection_reason, :content_generation, :evidence) do
      def rejected? = rejection_reason.present?
      def content_fingerprint = Analyzers::TextAnalysis.stable_content_fingerprint(extracted.body_text.to_s)

      # Evidence revisions describe what an assessor sees, not merely text.
      # A corrected source role/tier must invalidate an old assessment packet.
      def assessment_fingerprint
        attributes = {
          body: extracted.body_text.to_s.unicode_normalize(:nfkc).squish,
          title: (extracted.title.presence || fetched_title).to_s.unicode_normalize(:nfkc).squish,
          source_kind: (connector_result&.source_kind || source_metadata&.source_kind).to_s,
          authority_tier: (connector_result&.authority_tier || source_metadata&.authority_tier).to_s,
          authority_score: (connector_result&.authority_score || source_metadata&.authority_score).to_s,
          source_role: (source_metadata&.source_role || connector_result&.metadata_json&.fetch("source_role", nil)).to_s,
          independence_group: source_metadata&.independence_group.to_s,
          published_at: connector_result&.published_at&.utc&.iso8601,
          evidence_metadata: connector_result&.metadata_json || {}
        }
        Digest::SHA256.hexdigest(JSON.generate(attributes))
      end
    end
    def self.call(article:, html:, fetched_title:, current_depth:)
      staged = prepare(article:, html:, fetched_title:, current_depth:)
      if staged.rejected?
        ApplicationRecord.transaction do
          article.lock!
          raise StaleGeneration unless article.content_generation == staged.content_generation
          article.update!(fetch_status: :rejected, rejection_reason: staged.rejection_reason, content_generation: article.content_generation + 1)
        end
      else
        ApplicationRecord.transaction { publish!(article:, staged:) }
      end
      staged.extracted
    end

    def self.prepare(article:, html:, fetched_title:, current_depth:, evidence: false)
      new(article:, html:, fetched_title:, current_depth:, evidence:).prepare
    end

    def self.publish!(article:, staged:)
      new(article:, html: staged.html, fetched_title: staged.fetched_title, current_depth: staged.current_depth).publish!(staged)
    end

    def initialize(article:, html:, fetched_title:, current_depth:, evidence: false)
      @article = article
      @html = html
      @fetched_title = fetched_title
      @current_depth = current_depth
      @evidence = evidence
    end

    def prepare
      extracted = if Parsing::DocumentExtractor.document_url?(@article.normalized_url)
        extract_document
      else
        Parsing::MainContentExtractor.call(html: @html, url: @article.normalized_url)
      end

      unless Parsing::DocumentExtractor.document_url?(@article.normalized_url)
        detection = Parsing::ArticleDetector.call(html: @html)
        unless detection.article || (@evidence && substantive_official_page?(extracted.body_text))
          return staged(extracted, nil, nil, "not_article")
        end

        gate = Parsing::ContentQualityGate.call(
          body_text: extracted.body_text,
          title: extracted.title || @fetched_title,
          url: @article.normalized_url
        )

        unless gate.pass
          return staged(extracted, nil, nil, gate.reason.to_s)
        end
      end

      source_metadata = Sources::AuthorityClassifier.call(url: @article.normalized_url, host: @article.host, title: extracted.title || @fetched_title)
      connector_result = Sources::ConnectorRouter.call(
        url: @article.normalized_url, host: @article.host, title: extracted.title || @fetched_title, html: @html,
        source_kind: source_metadata.source_kind, authority_tier: source_metadata.authority_tier, authority_score: source_metadata.authority_score
      )
      staged(extracted, connector_result, source_metadata, nil)
    end

    def publish!(staged)
        @article.lock!
        raise StaleGeneration unless @article.content_generation == staged.content_generation
        extracted = staged.extracted
        source_metadata = staged.source_metadata
        connector_result = staged.connector_result
        @article.update!(
          title: extracted.title.presence || @fetched_title,
          body_text: extracted.body_text,
          excerpt: extracted.excerpt,
          fetch_status: :fetched,
          published_at: connector_result.published_at || @article.published_at,
          fetched_at: Time.current,
          content_fingerprint: Analyzers::TextAnalysis.stable_content_fingerprint(extracted.body_text.to_s),
          body_fingerprint: Analyzers::TextAnalysis.stable_content_fingerprint(extracted.body_text.to_s),
          main_content_path: extracted.main_content_path,
          source_kind: connector_result.source_kind || source_metadata.source_kind,
          authority_tier: connector_result.authority_tier || source_metadata.authority_tier,
          authority_score: connector_result.authority_score || source_metadata.authority_score,
          independence_group: source_metadata.independence_group,
          source_role: source_metadata.source_role || :unknown,
          metadata_json: connector_result.metadata_json || {},
          headline_divergence_score: nil
        )

        upsert_links!(extracted.links)
        store_html_snapshot!(strict: staged.evidence)
        @article.update_columns(content_generation: @article.content_generation + 1)
    end

    private

    def staged(extracted, connector_result, source_metadata, rejection_reason)
      Staged.new(extracted, connector_result, source_metadata, @html, @fetched_title, @current_depth, rejection_reason, @article.content_generation, @evidence)
    end

    def substantive_official_page?(body_text)
      metadata = Sources::AuthorityClassifier.call(url: @article.normalized_url, host: @article.host, title: @fetched_title)
      metadata.source_kind.to_sym.in?(%i[government_record legislative_record court_record company_filing press_release]) && body_text.to_s.length >= 300
    end

    def extract_document
      # Write the fetched HTML (which is actually binary content from Chromium dump-dom) to a temp file
      # For documents, we need to download the file directly
      require "open3"
      require "tempfile"

      ext = File.extname(URI.parse(@article.normalized_url).path)
      tempfile = Tempfile.new([ "document", ext ])
      tempfile.binmode
      tempfile.write(@html)
      tempfile.close

      doc = Parsing::DocumentExtractor.call(file_path: tempfile.path, url: @article.normalized_url)

      Parsing::MainContentExtractor::Result.new(
        title: doc.title,
        body_text: doc.body_text.presence || @fetched_title,
        excerpt: doc.body_text.to_s.truncate(280),
        main_content_path: "document:#{ext}",
        links: []
      )
    ensure
      tempfile&.unlink
    end

    def store_html_snapshot!(strict: false)
      HtmlSnapshot.store!(article: @article, html: @html, url: @article.normalized_url)
    rescue => e
      raise if strict
      Rails.logger.warn("Failed to store HTML snapshot for #{@article.normalized_url}: #{e.message}")
    end

    def upsert_links!(links)
      links.each do |link|
        next unless classifiable_link?(link[:href])
        target_article = find_or_create_target_article!(link)
        upsert_article_link!(link, target_article)
      end
    end

    def classifiable_link?(url)
      Investigations::UrlClassifier.call(url)
      true
    rescue Investigations::UrlClassifier::RejectedUrlError
      false
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
