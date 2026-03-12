require "test_helper"
require "ostruct"

class InvestigationsHelperTest < ActionView::TestCase
  include InvestigationsHelper

  test "te translates enum values" do
    assert_equal I18n.t("enums.verdict.supported"), te(:verdict, "supported")
    assert_equal I18n.t("enums.verdict.disputed"), te(:verdict, "disputed")
    assert_equal I18n.t("enums.stance.supports"), te(:stance, "supports")
  end

  test "te falls back to humanized string for unknown values" do
    assert_equal "Unknown thing", te(:verdict, "unknown_thing")
  end

  test "pipeline_step_name translates known steps" do
    assert_equal I18n.t("enums.pipeline_steps.fetch_root_article"), pipeline_step_name("fetch_root_article")
  end

  test "pipeline_step_name strips dynamic suffix" do
    assert_equal I18n.t("enums.pipeline_steps.fetch_root_article"), pipeline_step_name("fetch_root_article:123")
  end

  test "badge_class_for maps statuses to CSS classes" do
    assert_equal "badge badge--green", badge_class_for("completed")
    assert_equal "badge badge--green", badge_class_for("supported")
    assert_equal "badge badge--red", badge_class_for("failed")
    assert_equal "badge badge--red", badge_class_for("disputed")
    assert_equal "badge badge--slate", badge_class_for("not_checkable")
    assert_equal "badge badge--amber", badge_class_for("pending")
    assert_equal "badge badge--amber", badge_class_for("mixed")
  end

  test "verdict_icon returns correct symbols" do
    assert_equal "&#10003;", verdict_icon("supported")
    assert_equal "&#10007;", verdict_icon("disputed")
    assert_equal "&#8776;", verdict_icon("mixed")
    assert_equal "?", verdict_icon("needs_more_evidence")
    assert_equal "&#8943;", verdict_icon("pending")
  end

  test "score_percent formats as percentage" do
    assert_equal "85%", score_percent(85)
    assert_equal "0%", score_percent(0)
    assert_equal "100%", score_percent(100)
  end

  test "score_bar_width clamps to 100" do
    assert_equal 100, score_bar_width(1.5)
    assert_equal 50, score_bar_width(0.5)
    assert_equal 0, score_bar_width(0)
  end

  test "score_color_class returns correct class" do
    assert_equal "score-bar--green", score_color_class(0.8)
    assert_equal "score-bar--amber", score_color_class(0.5)
    assert_equal "score-bar--red", score_color_class(0.2)
  end

  test "authority_tier_description returns translated descriptions" do
    assert_includes authority_tier_description("primary"), I18n.t("helpers.authority_tier.primary")
    assert_includes authority_tier_description("unknown"), I18n.t("helpers.authority_tier.unknown")
  end

  test "source_role_description returns translated descriptions" do
    assert_includes source_role_description("news_reporting"), I18n.t("helpers.source_role.news_reporting")
  end

  test "headline_bait_explanation returns level-appropriate text" do
    assert_equal I18n.t("helpers.headline_bait.high"), headline_bait_explanation(0.8)
    assert_equal I18n.t("helpers.headline_bait.moderate"), headline_bait_explanation(0.5)
    assert_equal I18n.t("helpers.headline_bait.low"), headline_bait_explanation(0.2)
    assert_equal I18n.t("helpers.headline_bait.none"), headline_bait_explanation(0.0)
  end

  test "fallacy_severity_badge returns correct badge" do
    assert_equal "badge badge--red", fallacy_severity_badge("high")
    assert_equal "badge badge--amber", fallacy_severity_badge("medium")
    assert_equal "badge badge--slate", fallacy_severity_badge("low")
  end

  test "pipeline_step_duration formats seconds" do
    step = OpenStruct.new(started_at: 45.seconds.ago, finished_at: Time.current)
    assert_match(/\d+s/, pipeline_step_duration(step))
  end

  test "pipeline_step_duration formats minutes" do
    step = OpenStruct.new(started_at: 90.seconds.ago, finished_at: Time.current)
    assert_match(/1m \d+s/, pipeline_step_duration(step))
  end

  test "pipeline_step_duration returns nil without started_at" do
    step = OpenStruct.new(started_at: nil, finished_at: nil)
    assert_nil pipeline_step_duration(step)
  end

  test "active_step_name returns running step name" do
    root = Article.create!(url: "https://helper.com/a", normalized_url: "https://helper.com/a", host: "helper.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)
    investigation.pipeline_steps.create!(name: "extract_claims", status: :running, started_at: Time.current)

    result = active_step_name(investigation)
    assert_equal I18n.t("enums.pipeline_steps.extract_claims"), result
  end

  test "active_step_name returns nil when no active step" do
    root = Article.create!(url: "https://helper2.com/a", normalized_url: "https://helper2.com/a", host: "helper2.com")
    investigation = Investigation.create!(submitted_url: root.url, normalized_url: root.normalized_url, root_article: root)

    assert_nil active_step_name(investigation)
  end
end
