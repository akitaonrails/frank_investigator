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
    base = "inline-flex items-center px-2.5 py-0.5 rounded-full text-sm font-bold"
    case status.to_s
    when "completed", "supported", "checkable", "crawled"
      "#{base} bg-verdict-green/12 text-verdict-green"
    when "failed", "disputed"
      "#{base} bg-verdict-red/12 text-verdict-red"
    when "not_checkable", "ambiguous", "skipped"
      "#{base} bg-verdict-slate/12 text-verdict-slate"
    else
      "#{base} bg-verdict-amber/12 text-verdict-amber"
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
    [ (value.to_f * 100).round, 100 ].min
  end

  def score_color_class(value)
    v = value.to_f
    if v >= 0.7
      "bg-verdict-green"
    elsif v >= 0.4
      "bg-verdict-amber"
    else
      "bg-verdict-red"
    end
  end

  def fallacy_severity_badge(severity)
    base = "inline-flex items-center px-2.5 py-0.5 rounded-full text-sm font-bold"
    case severity.to_s
    when "high" then "#{base} bg-verdict-red/12 text-verdict-red"
    when "medium" then "#{base} bg-verdict-amber/12 text-verdict-amber"
    else "#{base} bg-verdict-slate/12 text-verdict-slate"
    end
  end

  def fallacy_type_label(type)
    t("helpers.fallacy_types.#{type}", default: type.to_s.tr("_", " ").capitalize)
  end

  def active_step_name(investigation)
    running = investigation.pipeline_steps.find_by(status: "running")
    return pipeline_step_name(running.name) if running

    processing = investigation.pipeline_steps.find_by(status: "processing")
    return pipeline_step_name(processing.name) if processing

    nil
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

  def render_reason_summary(text)
    return "" if text.blank?

    html = ERB::Util.html_escape(text)
    # Convert markdown links [text](url) to <a> tags
    html = html.gsub(/\[([^\]]+)\]\((https?:\/\/[^\)]+)\)/) do
      %(<a href="#{$2}" target="_blank" rel="noopener">#{$1}</a>)
    end
    # Convert **bold** to <strong>
    html = html.gsub(/\*\*([^*]+)\*\*/, '<strong>\1</strong>')
    html.html_safe
  end
end
