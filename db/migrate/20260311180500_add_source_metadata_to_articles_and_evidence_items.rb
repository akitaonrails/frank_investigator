class AddSourceMetadataToArticlesAndEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    change_table :articles, bulk: true do |t|
      t.string :source_kind, null: false, default: "unknown"
      t.string :authority_tier, null: false, default: "unknown"
      t.decimal :authority_score, precision: 5, scale: 2, null: false, default: 0
      t.string :independence_group
    end

    add_index :articles, :source_kind
    add_index :articles, :authority_tier
    add_index :articles, :independence_group

    change_table :evidence_items, bulk: true do |t|
      t.decimal :relevance_score, precision: 5, scale: 2, null: false, default: 0
      t.string :source_kind
    end

    add_index :evidence_items, :source_kind
  end
end
