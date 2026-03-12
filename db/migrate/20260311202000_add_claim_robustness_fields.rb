class AddClaimRobustnessFields < ActiveRecord::Migration[8.1]
  def change
    # Evidence provenance: lock content hashes at assessment time
    add_column :verdict_snapshots, :evidence_content_hashes, :json, default: {}, null: false

    # Source correction detection: track last known body fingerprint per article
    add_column :articles, :body_fingerprint, :string
    add_column :articles, :body_changed_since_assessment, :boolean, default: false, null: false

    # Claim mutation tracking: link variant claims to their canonical parent
    add_reference :claims, :canonical_parent, foreign_key: { to_table: :claims }, null: true
    add_column :claims, :variant_of_fingerprint, :string
    add_index :claims, :variant_of_fingerprint
  end
end
