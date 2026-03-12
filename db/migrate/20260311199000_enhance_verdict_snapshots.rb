class EnhanceVerdictSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :verdict_snapshots, :previous_confidence_score, :decimal, precision: 5, scale: 2
    add_column :verdict_snapshots, :evidence_snapshot, :json, default: [], null: false
    add_column :verdict_snapshots, :evidence_count, :integer, default: 0, null: false

    change_column :verdict_snapshots, :reason_summary, :text, limit: nil
  end
end
