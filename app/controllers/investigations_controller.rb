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

    if params[:json].present?
      redirect_to investigation_path(investigation, format: :json), status: :see_other
    else
      redirect_to investigation_path(investigation), status: :see_other
    end
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

    respond_to do |format|
      format.html
      format.json do
        if @investigation.completed? || @investigation.failed?
          render json: investigation_json
        else
          response.headers["Retry-After"] = "5"
          render json: investigation_pending_json, status: :accepted
        end
      end
    end
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

  def investigation_pending_json
    completed_steps = @pipeline_steps.select(&:completed?).size
    total_steps = @pipeline_steps.size
    {
      id: @investigation.id,
      url: @investigation.normalized_url,
      status: @investigation.status,
      ready: false,
      poll_url: investigation_url(@investigation, format: :json),
      retry_after: 5,
      progress: {
        completed_steps: completed_steps,
        total_steps: total_steps,
        current_step: @pipeline_steps.find { |s| s.status.in?(%w[running processing]) }&.name,
        percent: total_steps > 0 ? ((completed_steps.to_f / total_steps) * 100).round : 0
      },
      created_at: @investigation.created_at,
      updated_at: @investigation.updated_at
    }
  end

  def investigation_json
    {
      id: @investigation.id,
      url: @investigation.normalized_url,
      status: @investigation.status,
      ready: true,
      checkability_status: @investigation.checkability_status,
      headline_bait_score: @investigation.headline_bait_score,
      overall_confidence_score: @investigation.overall_confidence_score,
      created_at: @investigation.created_at,
      updated_at: @investigation.updated_at,
      root_article: root_article_json,
      rhetorical_analysis: @investigation.rhetorical_analysis,
      claims: @checkable_claims.map { |a| claim_assessment_json(a) },
      uncheckable_claims: @uncheckable_claims.map { |a| uncheckable_claim_json(a) },
      sources: @links.map { |link| source_link_json(link) },
      pipeline: @pipeline_steps.map { |step| pipeline_step_json(step) },
      failure: @failure_info
    }
  end

  def root_article_json
    return nil unless @root_article
    {
      url: @root_article.normalized_url,
      title: @root_article.title,
      host: @root_article.host,
      fetch_status: @root_article.fetch_status,
      source_kind: @root_article.source_kind,
      authority_tier: @root_article.authority_tier,
      authority_score: @root_article.authority_score.to_f,
      source_role: @root_article.source_role,
      excerpt: @root_article.excerpt,
      headline_divergence_score: @root_article.headline_divergence_score.to_f,
      linked_sources_count: @root_article.sourced_links.count
    }
  end

  def claim_assessment_json(assessment)
    {
      id: assessment.id,
      claim: assessment.claim.canonical_text,
      claim_kind: assessment.claim.claim_kind,
      time_scope: assessment.claim.time_scope,
      verdict: assessment.verdict,
      confidence_score: assessment.confidence_score.to_f,
      authority_score: assessment.authority_score.to_f,
      independence_score: assessment.independence_score.to_f,
      timeliness_score: assessment.timeliness_score.to_f,
      conflict_score: assessment.conflict_score.to_f,
      citation_depth_score: assessment.citation_depth_score.to_f,
      primary_vetoed: assessment.primary_vetoed?,
      unsubstantiated_viral: assessment.unsubstantiated_viral?,
      unanimous: assessment.unanimous?,
      reason_summary: assessment.reason_summary,
      missing_evidence_summary: assessment.missing_evidence_summary,
      disagreement_details: assessment.disagreement_details,
      stale_at: assessment.stale_at,
      staleness_reason: assessment.staleness_reason,
      reassessment_count: assessment.reassessment_count,
      assessed_at: assessment.assessed_at,
      evidence: assessment.evidence_items.order(authority_score: :desc).map { |item| evidence_item_json(item) },
      llm_verdicts: assessment.llm_interactions
        .where(interaction_type: :assessment, status: :completed)
        .map { |i| llm_interaction_json(i) },
      verdict_history: assessment.verdict_snapshots.chronological.map { |s| verdict_snapshot_json(s) }
    }
  end

  def uncheckable_claim_json(assessment)
    {
      claim: assessment.claim.canonical_text,
      claim_kind: assessment.claim.claim_kind,
      checkability_status: assessment.checkability_status,
      reason_summary: assessment.reason_summary
    }
  end

  def evidence_item_json(item)
    {
      source_url: item.source_url,
      title: item.article&.title,
      host: item.article&.host,
      source_kind: item.source_kind,
      authority_tier: item.article&.authority_tier,
      authority_score: item.authority_score.to_f,
      relevance_score: item.relevance_score.to_f,
      stance: item.stance,
      source_role: item.article&.source_role,
      headline_divergence_score: item.article&.headline_divergence_score.to_f,
      excerpt: item.excerpt
    }
  end

  def llm_interaction_json(interaction)
    {
      model_id: interaction.model_id,
      verdict: interaction.response_json&.dig("verdict"),
      confidence_score: interaction.response_json&.dig("confidence_score").to_f,
      reason_summary: interaction.response_json&.dig("reason_summary")
    }
  end

  def verdict_snapshot_json(snapshot)
    {
      verdict: snapshot.verdict,
      confidence_score: snapshot.confidence_score.to_f,
      previous_verdict: snapshot.previous_verdict,
      previous_confidence_score: snapshot.previous_confidence_score&.to_f,
      evidence_count: snapshot.evidence_count,
      trigger: snapshot.trigger,
      created_at: snapshot.created_at
    }
  end

  def source_link_json(link)
    target = link.target_article
    {
      href: link.href,
      anchor_text: link.anchor_text,
      host: target.host,
      source_kind: target.source_kind,
      authority_tier: target.authority_tier,
      authority_score: target.authority_score.to_f,
      source_role: target.source_role,
      follow_status: link.follow_status
    }
  end

  def pipeline_step_json(step)
    {
      name: step.name,
      status: step.status,
      started_at: step.started_at,
      finished_at: step.finished_at,
      error_class: step.error_class,
      error_message: step.error_message
    }
  end

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
    respond_to do |format|
      format.html { render file: Rails.root.join("public/404.html"), layout: false, status: :not_found }
      format.json { render json: { error: "not_found" }, status: :not_found }
    end
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
