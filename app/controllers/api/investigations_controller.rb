module Api
  class InvestigationsController < ActionController::API
    before_action :authenticate_api_token!

    LIST_LIMIT = 10

    # GET /api/investigations
    # GET /api/investigations?q=<term>
    #
    # Without a query: the 10 most recent investigations.
    # With ?q=: the 10 most recent investigations whose original headline or
    # honest headline matches the term (case-insensitive substring).
    def index
      scope = Investigation.includes(:root_article).order(created_at: :desc)

      query = params[:q].to_s.strip
      if query.present?
        like = "%#{sanitize_like(query)}%"
        scope = scope.left_joins(:root_article).where(
          "LOWER(articles.title) LIKE LOWER(:q) ESCAPE '\\' OR " \
          "LOWER(investigations.honest_headline) LIKE LOWER(:q) ESCAPE '\\'",
          q: like
        )
      end

      investigations = scope.limit(LIST_LIMIT)

      render json: {
        count: investigations.size,
        query: query.presence,
        investigations: investigations.map { |inv| list_item_json(inv) }
      }
    end

    def create
      url = params[:url].to_s.strip

      if url.blank?
        return render json: { error: "url is required" }, status: :unprocessable_entity
      end

      if url.length > 2048
        return render json: { error: "url too long (max 2048)" }, status: :unprocessable_entity
      end

      normalized_url = Investigations::UrlNormalizer.call(url)
      Investigations::UrlClassifier.call(normalized_url)

      investigation = Investigations::EnsureStarted.call(submitted_url: normalized_url)

      render json: {
        slug: investigation.slug,
        status: investigation.status,
        url: investigation.normalized_url,
        report_url: investigation_url(investigation)
      }, status: :created
    rescue Investigations::UrlNormalizer::InvalidUrlError => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue Investigations::UrlClassifier::RejectedUrlError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def list_item_json(investigation)
      article = investigation.root_article
      {
        slug: investigation.slug,
        status: investigation.status,
        datetime: investigation.created_at&.iso8601,
        completed_at: investigation.analysis_completed_at&.iso8601,
        outlet: article&.host,
        original_title: article&.title,
        honest_title: investigation.honest_headline,
        summary: investigation_summary(investigation),
        investigation_url: investigation_url(investigation),
        original_url: article&.url
      }
    end

    # The human-readable conclusion if the LLM summary ran, falling back to the
    # plain stored summary text.
    def investigation_summary(investigation)
      investigation.llm_summary&.dig("conclusion").presence || investigation.summary.presence
    end

    # Escape LIKE wildcards in user input so a search term containing % or _
    # is treated literally (paired with ESCAPE '\' in the query).
    def sanitize_like(term)
      term.gsub(/[\\%_]/) { |char| "\\#{char}" }
    end

    def authenticate_api_token!
      secret = ENV["FRANK_AUTH_SECRET"]
      return render_unauthorized("FRANK_AUTH_SECRET not configured") if secret.blank?

      token = request.headers["Authorization"]&.sub(/\ABearer\s+/i, "")
      render_unauthorized("Invalid or missing token") unless ActiveSupport::SecurityUtils.secure_compare(token.to_s, secret)
    end

    def render_unauthorized(message)
      render json: { error: message }, status: :unauthorized
    end
  end
end
