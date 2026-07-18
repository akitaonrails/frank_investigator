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
      raw_url = params[:main_url].presence || params[:url]
      return api_error(:url_must_be_string) unless raw_url.is_a?(String)
      url = raw_url.strip

      if url.blank?
        return api_error(:url_required)
      end

      if url.length > 2048
        return api_error(:url_too_long, max: 2048)
      end

      [ :news_urls, :evidence_urls ].each do |key|
        next unless params.key?(key)
        unless params[key].is_a?(Array) && params[key].all? { |item| item.is_a?(String) }
          return api_error(:url_array_required, field: key)
        end
      end

      grouped_input = params.key?(:news_urls) || params.key?(:evidence_urls)
      preflight = grouped_input ? Investigations::GroupSubmissionPreflight.call(main_url: url, news_urls: params[:news_urls], evidence_urls: params[:evidence_urls]) : nil
      submission = preflight&.grouped? && Investigations::SubmitGroup.call(
        main_url: preflight.main_url,
        news_urls: preflight.news_urls,
        evidence_urls: preflight.evidence_urls,
        preflight:
      )
      investigation = submission ? submission.main_investigation : Investigations::EnsureStarted.call(submitted_url: url)

      render json: {
        slug: investigation.slug,
        status: investigation.status,
        url: investigation.normalized_url,
        report_url: investigation_url(investigation),
        **Investigations::ReadinessPresenter.call(investigation)
      }, status: :created
    rescue Investigations::UrlNormalizer::InvalidUrlError
      api_error(:invalid_url)
    rescue Investigations::UrlClassifier::RejectedUrlError
      api_error(:url_rejected)
    rescue Investigations::SubmitGroup::ConflictError, Investigations::GroupSubmissionPreflight::ConflictError, ArgumentError
      api_error(:group_submission_invalid)
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

    def api_error(key, **options)
      render json: { error: I18n.t("api.investigations.errors.#{key}", **options) }, status: :unprocessable_entity
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
