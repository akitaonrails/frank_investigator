class InvestigationsController < ApplicationController
  MAX_URL_LENGTH = 2048

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  def home
    @submitted_url = params[:url].to_s.strip
    return render :home if @submitted_url.blank?

    if @submitted_url.length > MAX_URL_LENGTH
      @error_message = t("investigations.errors.url_too_long", max: MAX_URL_LENGTH)
      return render :home, status: :unprocessable_entity
    end

    @normalized_url = Investigations::UrlNormalizer.call(@submitted_url)
    return redirect_to(root_path(url: @normalized_url), status: :see_other) if @submitted_url != @normalized_url

    Investigations::UrlClassifier.call(@normalized_url)

    investigation = Investigations::EnsureStarted.call(submitted_url: @normalized_url)
    redirect_to investigation_path(investigation), status: :see_other
  rescue Investigations::UrlNormalizer::InvalidUrlError => error
    @error_message = error.message
    render :home, status: :unprocessable_entity
  rescue Investigations::UrlClassifier::RejectedUrlError => error
    @error_message = error.message
    render :home, status: :unprocessable_entity
  end

  def show
    @investigation = Investigation.find(params[:id])
    @root_article = @investigation.root_article
    @checkable_claims = @investigation.claim_assessments
      .includes(claim: {}, evidence_items: :article, llm_interactions: {}, verdict_snapshots: {})
      .where(checkability_status: "checkable")
      .order(confidence_score: :desc)
    @uncheckable_claims = @investigation.claim_assessments
      .includes(:claim)
      .where(checkability_status: %w[not_checkable ambiguous])
      .order(created_at: :asc)
    @pipeline_steps = @investigation.pipeline_steps.order(:created_at)
    @links = @root_article&.sourced_links&.includes(:target_article)&.order(:position) || []
    @failure_info = build_failure_info
  end

  def graph_data
    investigation = Investigation.find(params[:id])
    root = investigation.root_article

    nodes = []
    edges = []

    if root.present?
      nodes << node_hash(root, :root)

      root.sourced_links.includes(:target_article).each do |link|
        target = link.target_article
        nodes << node_hash(target, :source)
        edges << { source: root.id, target: target.id, label: link.anchor_text.to_s.truncate(40) }
      end

      investigation.claims.includes(:articles).each do |claim|
        claim_node_id = "claim_#{claim.id}"
        nodes << { id: claim_node_id, label: claim.canonical_text.truncate(60), kind: "claim", claim_kind: claim.claim_kind }
        claim.articles.each do |article|
          existing = nodes.find { |n| n[:id] == article.id }
          nodes << node_hash(article, :source) unless existing
          edges << { source: article.id, target: claim_node_id, label: "mentions" }
        end
      end
    end

    render json: { nodes: nodes.uniq { |n| n[:id] }, edges: }
  end

  private

  def build_failure_info
    return nil unless @investigation.failed?

    failed_steps = @pipeline_steps.select(&:failed?)
    return nil if failed_steps.empty?

    step = failed_steps.first
    {
      step_name: t("enums.pipeline_steps.#{step.name.split(':').first}", default: step.name.humanize),
      error_class: step.error_class,
      error_message: step.error_message,
      user_message: failure_user_message(step)
    }
  end

  def failure_user_message(step)
    case step.name
    when "fetch_root_article"
      if step.error_class.to_s.include?("InterstitialDetected")
        t("investigations.failures.interstitial_detected")
      elsif step.error_class.to_s.include?("FetchError")
        t("investigations.failures.fetch_error")
      elsif step.error_class.to_s.include?("Timeout")
        t("investigations.failures.timeout")
      else
        t("investigations.failures.generic_fetch")
      end
    when "extract_claims"
      t("investigations.failures.extract_claims")
    when "assess_claims"
      t("investigations.failures.assess_claims")
    else
      t("investigations.failures.generic", step_name: t("enums.pipeline_steps.#{step.name.split(':').first}", default: step.name.humanize).downcase)
    end
  end

  def render_not_found
    render file: Rails.root.join("public/404.html"), layout: false, status: :not_found
  end

  def node_hash(article, role)
    {
      id: article.id,
      label: article.title.presence || article.host,
      kind: role.to_s,
      host: article.host,
      source_kind: article.source_kind,
      authority_tier: article.authority_tier,
      authority_score: article.authority_score.to_f,
      source_role: article.source_role,
      fetch_status: article.fetch_status
    }
  end
end
