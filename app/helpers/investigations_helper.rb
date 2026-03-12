module InvestigationsHelper
  def score_percent(value)
    number_to_percentage(value.to_f, precision: 0)
  end

  def badge_class_for(status)
    case status.to_s
    when "completed", "supported", "checkable", "crawled"
      "badge badge--green"
    when "failed", "disputed"
      "badge badge--red"
    when "not_checkable", "ambiguous", "skipped"
      "badge badge--slate"
    else
      "badge badge--amber"
    end
  end

  def verdict_icon(verdict)
    case verdict.to_s
    when "supported" then "&#10003;"
    when "disputed" then "&#10007;"
    when "mixed" then "&#8776;"
    when "needs_more_evidence" then "?"
    else "&#8943;"
    end
  end

  def authority_tier_description(tier)
    case tier.to_s
    when "primary" then "Authenticated primary source (government records, official statistics, legal documents)"
    when "secondary" then "Established secondary source (major newsrooms, institutional reports)"
    when "low" then "Lower-authority source (blogs, social media, unverified)"
    else "Authority not yet classified"
    end
  end

  def source_role_description(role)
    case role.to_s
    when "authenticated_legal_text" then "Authenticated legal text with official provenance"
    when "neutral_statistics" then "Statistical data from non-partisan agency"
    when "oversight" then "Independent oversight or audit body"
    when "official_position" then "Official government position (may reflect political stance)"
    when "research_discovery" then "Academic or research publication"
    when "news_reporting" then "Journalistic reporting"
    else "Role not classified"
    end
  end

  def headline_bait_explanation(score)
    if score >= 0.7
      "High likelihood of sensationalized headline. The title likely exaggerates or misrepresents the article body."
    elsif score >= 0.4
      "Moderate headline embellishment. Some claims in the title may not be fully supported by the article."
    elsif score > 0.0
      "Low headline bait. The title appears reasonably aligned with the article content."
    else
      "Not yet analyzed."
    end
  end

  def score_bar_width(value)
    [(value.to_f * 100).round, 100].min
  end

  def score_color_class(value)
    v = value.to_f
    if v >= 0.7
      "score-bar--green"
    elsif v >= 0.4
      "score-bar--amber"
    else
      "score-bar--red"
    end
  end

  def fallacy_severity_badge(severity)
    case severity.to_s
    when "high" then "badge badge--red"
    when "medium" then "badge badge--amber"
    else "badge badge--slate"
    end
  end

  def fallacy_type_label(type)
    type.to_s.tr("_", " ").capitalize
  end

  def pipeline_step_duration(step)
    return nil unless step.started_at
    finish = step.finished_at || Time.current
    seconds = (finish - step.started_at).round
    if seconds < 60
      "#{seconds}s"
    else
      "#{seconds / 60}m #{seconds % 60}s"
    end
  end
end
