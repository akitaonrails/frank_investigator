module InvestigationsHelper
  def te(enum_name, value)
    t("enums.#{enum_name}.#{value}", default: value.to_s.humanize)
  end

  def pipeline_step_name(name)
    # Strip dynamic suffixes like "fetch_linked_article:123"
    base = name.to_s.split(":").first
    t("enums.pipeline_steps.#{base}", default: name.to_s.humanize)
  end

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
    t("helpers.authority_tier.#{tier}", default: t("helpers.authority_tier.unknown"))
  end

  def source_role_description(role)
    t("helpers.source_role.#{role}", default: t("helpers.source_role.unknown"))
  end

  def headline_bait_explanation(score)
    if score >= 0.7
      t("helpers.headline_bait.high")
    elsif score >= 0.4
      t("helpers.headline_bait.moderate")
    elsif score > 0.0
      t("helpers.headline_bait.low")
    else
      t("helpers.headline_bait.none")
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
    t("helpers.fallacy_types.#{type}", default: type.to_s.tr("_", " ").capitalize)
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
