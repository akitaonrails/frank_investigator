class AddInvestigationGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :investigation_groups do |t|
      t.references :main_investigation, null: false, index: false, foreign_key: { to_table: :investigations }
      t.integer :evidence_revision, null: false, default: 0
      t.integer :enriched_revision, null: false, default: 0
      t.string :enrichment_fingerprint
      t.string :enrichment_token
      t.string :enrichment_target_fingerprint
      t.string :enrichment_applied_fingerprint
      t.datetime :enrichment_lease_expires_at
      t.integer :enrichment_attempts, null: false, default: 0
      t.text :enrichment_error
      t.datetime :enrichment_retry_due_at
      t.string :enrichment_delivery_token
      t.datetime :enrichment_delivery_expires_at
      t.timestamps
    end
    add_index :investigation_groups, :main_investigation_id, unique: true, name: "idx_investigation_groups_main_unique"

    add_reference :investigations, :investigation_group, foreign_key: true, null: true
    add_column :investigations, :group_membership_kind, :string
    add_column :investigations, :evidence_revision_assessed, :integer, null: false, default: 0
    add_column :investigations, :reconciliation_token, :string
    add_column :investigations, :reconciliation_revision, :integer
    add_column :investigations, :reconciliation_lease_expires_at, :datetime
    add_column :investigations, :reconciliation_attempts, :integer, null: false, default: 0
    add_column :investigations, :evidence_reconciliation_attempts_revision, :integer
    add_column :investigations, :evidence_reconciliation_retry_due_at, :datetime
    add_column :investigations, :evidence_reconciliation_retry_delivery_token, :string
    add_column :investigations, :evidence_reconciliation_retry_delivery_expires_at, :datetime
    add_column :investigations, :reconciliation_error, :text
    add_column :investigations, :reconciliation_enrichment_pending_revision, :integer
    add_column :investigations, :reconciliation_enrichment_delivered_revision, :integer
    add_column :investigations, :reconciliation_enrichment_delivery_token, :string
    add_column :investigations, :reconciliation_enrichment_delivery_expires_at, :datetime
    add_column :investigations, :legacy_enrichment_token, :string
    add_column :investigations, :legacy_enrichment_lease_expires_at, :datetime
    add_column :investigations, :legacy_enrichment_target_fingerprint, :string
    add_column :investigations, :legacy_enrichment_applied_fingerprint, :string
    add_column :investigations, :legacy_enrichment_attempts, :integer, null: false, default: 0
    add_column :investigations, :legacy_enrichment_error, :text
    add_column :investigations, :legacy_enrichment_retry_due_at, :datetime
    add_column :investigations, :legacy_enrichment_delivery_token, :string
    add_column :investigations, :legacy_enrichment_delivery_expires_at, :datetime
    # Submission delivery is part of the original grouped feature. Keeping it
    # here makes a fresh install and an upgrade have the same schema.
    add_column :investigations, :kickoff_due_at, :datetime
    add_column :investigations, :kickoff_delivery_token, :string
    add_column :investigations, :kickoff_delivery_expires_at, :datetime
    add_column :investigations, :kickoff_delivered_at, :datetime
    add_index :investigations, :kickoff_due_at

    create_table :investigation_group_evidence_sources do |t|
      t.references :investigation_group, null: false, foreign_key: true
      t.references :article, null: false, foreign_key: true
      t.string :submitted_url, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts_count, null: false, default: 0
      t.string :last_error_class
      t.text :last_error_message
      t.datetime :ready_at
      t.string :content_fingerprint
      t.string :fetch_token
      t.datetime :fetch_lease_expires_at
      t.datetime :fetch_retry_due_at
      t.string :fetch_delivery_token
      t.datetime :fetch_delivery_expires_at
      t.string :fetch_attempts_generation
      t.datetime :terminal_at
      t.timestamps
    end
    add_index :investigation_group_evidence_sources, [ :investigation_group_id, :article_id ], unique: true, name: "idx_group_evidence_source_unique"
    add_index :investigation_group_evidence_sources, :fetch_retry_due_at

    create_table :investigation_submission_locks do |t|
      t.string :key, null: false
      t.integer :version, null: false, default: 0
      t.timestamps
    end
    add_index :investigation_submission_locks, :key, unique: true

    add_column :articles, :content_generation, :integer, null: false, default: 0

    # Do not add a uniqueness constraint to legacy evidence_items here: old
    # installations can contain historical duplicates and migrations must never
    # delete audit history. Runtime upserts remain idempotent by URL.
  end
end
