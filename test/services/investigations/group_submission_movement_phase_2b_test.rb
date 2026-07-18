require "test_helper"

class Investigations::GroupSubmissionMovementPhase2bTest < ActiveSupport::TestCase
  test "disposable predicate rejects every operational and lineage state" do
    group, member = disposable_group("phase2b-disposable")
    assert Investigations::GroupSubmissionPreflight.disposable_group?(group)

    mutations = {
      evidence_revision: 1, enriched_revision: 1, enrichment_attempts: 1,
      enrichment_token: "token", enrichment_error: "error", enrichment_fingerprint: "fingerprint",
      enrichment_target_fingerprint: "target", enrichment_applied_fingerprint: "applied",
      enrichment_retry_due_at: Time.current, enrichment_lease_expires_at: Time.current,
      enrichment_delivery_token: "delivery", enrichment_delivery_expires_at: Time.current
    }
    mutations.each do |field, value|
      group.update!(field => value)
      refute Investigations::GroupSubmissionPreflight.disposable_group?(group), field
      group.update!(field => (field.to_s.end_with?("revision", "attempts") ? 0 : nil))
    end
    member.update!(auto_submitted_from: Investigations::EnsureStarted.call(submitted_url: "https://example.org/phase2b-parent"))
    group.reload
    refute Investigations::GroupSubmissionPreflight.disposable_group?(group)

    group, = disposable_group("phase2b-evidence")
    article = Article.create!(url: "https://www.govinfo.gov/phase2b-evidence", normalized_url: "https://www.govinfo.gov/phase2b-evidence", host: "www.govinfo.gov")
    group.evidence_sources.create!(article:, submitted_url: article.url)
    refute Investigations::GroupSubmissionPreflight.disposable_group?(group)
  end

  test "moving a disposable member clears all group reset fields without touching root history" do
    old_group, member = disposable_group("phase2b-move")
    member.update!(Investigations::SubmitGroup.new(main_url: "https://example.com/x", news_urls: [], evidence_urls: [], auto_submitted_from: nil).send(:group_reset_attributes).transform_values { |v| v.is_a?(Integer) ? 9 : "stale" })
    root_id, root_updated_at, member_updated_at = member.root_article_id, member.root_article.updated_at, member.updated_at
    step = member.pipeline_steps.create!(name: "kickoff", status: :completed, finished_at: Time.current)
    member.update_columns(kickoff_due_at: 1.hour.from_now, kickoff_delivery_token: "root-token", kickoff_delivery_expires_at: 1.hour.from_now, kickoff_delivered_at: Time.current)

    result = Investigations::SubmitGroup.call(main_url: "https://example.net/phase2b-new-main", news_urls: [ member.normalized_url ])
    member.reload
    assert_equal result.group.id, member.investigation_group_id
    Investigations::SubmitGroup.new(main_url: "https://example.com/x", news_urls: [], evidence_urls: [], auto_submitted_from: nil).send(:group_reset_attributes).each do |field, value|
      value.nil? ? assert_nil(member.public_send(field), field) : assert_equal(value, member.public_send(field), field)
    end
    assert_equal root_id, member.root_article_id
    assert_equal root_updated_at, member.root_article.reload.updated_at
    assert_operator member.updated_at, :>=, member_updated_at
    assert_equal step.id, member.pipeline_steps.find_by!(name: "kickoff").id
    assert_equal "root-token", member.kickoff_delivery_token
    assert_not InvestigationGroup.exists?(old_group.id)
  end

  private

  def disposable_group(slug)
    member = Investigations::EnsureStarted.call(submitted_url: "https://example.com/#{slug}")
    group = InvestigationGroup.create!(main_investigation: member)
    member.update!(investigation_group: group, group_membership_kind: :manual)
    [ group, member ]
  end
end
