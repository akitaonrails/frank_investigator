class AddProvenanceTables < ActiveRecord::Migration[8.1]
  def change
    create_table :html_snapshots do |t|
      t.references :article, null: false, foreign_key: true
      t.binary :compressed_html, null: false
      t.string :content_fingerprint, null: false
      t.integer :original_size, null: false
      t.string :fetch_url, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end

    add_index :html_snapshots, :content_fingerprint, unique: true

    create_table :llm_interactions do |t|
      t.references :investigation, null: false, foreign_key: true
      t.references :claim_assessment, foreign_key: true
      t.string :interaction_type, null: false, default: "assessment"
      t.string :model_id, null: false
      t.text :prompt_text, null: false
      t.text :response_text
      t.json :response_json, default: {}
      t.string :evidence_packet_fingerprint
      t.string :status, null: false, default: "pending"
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :latency_ms
      t.decimal :cost_usd, precision: 8, scale: 6
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    add_index :llm_interactions, [:evidence_packet_fingerprint, :model_id], name: "idx_llm_interactions_cache_key"
    add_index :llm_interactions, :interaction_type
    add_index :llm_interactions, :model_id

    add_column :evidence_items, :content_fingerprint, :string
    add_index :evidence_items, :content_fingerprint
  end
end
