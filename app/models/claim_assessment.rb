class ClaimAssessment < ApplicationRecord
  broadcasts_refreshes_to :investigation

  enum :verdict, {
    pending: "pending",
    supported: "supported",
    disputed: "disputed",
    mixed: "mixed",
    needs_more_evidence: "needs_more_evidence",
    not_checkable: "not_checkable"
  }, default: :pending, validate: true, prefix: :verdict

  enum :checkability_status, {
    pending: "pending",
    checkable: "checkable",
    ambiguous: "ambiguous",
    not_checkable: "not_checkable"
  }, default: :pending, validate: true, prefix: :checkability

  belongs_to :investigation
  belongs_to :claim

  has_many :evidence_items, dependent: :destroy
  has_many :llm_interactions, dependent: :nullify
  has_many :verdict_snapshots, dependent: :destroy

  CONFIDENCE_CHANGE_THRESHOLD = 0.15

  def record_verdict_change!(new_verdict:, new_confidence:, new_reason:, trigger:, triggered_by: nil)
    is_first = verdict_snapshots.none?
    verdict_changed = verdict.to_s != new_verdict.to_s
    confidence_shifted = (confidence_score.to_f - new_confidence.to_f).abs >= CONFIDENCE_CHANGE_THRESHOLD

    if is_first || verdict_changed || confidence_shifted
      verdict_snapshots.create!(
        verdict: new_verdict,
        previous_verdict: is_first ? nil : verdict,
        confidence_score: new_confidence,
        previous_confidence_score: is_first ? nil : confidence_score,
        reason_summary: new_reason.to_s,
        trigger: trigger,
        triggered_by: triggered_by,
        evidence_count: evidence_items.count,
        evidence_snapshot: build_evidence_snapshot
      )
    end

    update!(
      verdict: new_verdict,
      confidence_score: new_confidence,
      reason_summary: new_reason
    )
  end

  def verdict_changed_count
    verdict_snapshots.verdict_changes.count
  end

  private

  def build_evidence_snapshot
    evidence_items.includes(:article).map do |item|
      {
        source_url: item.source_url,
        title: item.article&.title,
        stance: item.stance,
        authority_score: item.authority_score.to_f,
        published_at: item.published_at&.iso8601
      }
    end
  end
end
