class AddStalenessTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :claim_assessments, :assessed_at, :datetime
    add_column :claim_assessments, :stale_at, :datetime
    add_column :claim_assessments, :staleness_reason, :string
    add_column :claim_assessments, :reassessment_count, :integer, default: 0, null: false

    add_index :claim_assessments, :stale_at
    add_index :claim_assessments, :assessed_at

    add_column :claims, :evidence_article_count, :integer, default: 0, null: false
  end
end
