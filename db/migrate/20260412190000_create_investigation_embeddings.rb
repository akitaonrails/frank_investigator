class CreateInvestigationEmbeddings < ActiveRecord::Migration[8.1]
  def change
    create_table :investigation_embeddings do |t|
      t.references :investigation, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.string :model_id, null: false
      t.integer :dimensions, null: false
      t.string :content_digest, null: false
      t.text :embedding_json
      t.datetime :indexed_at
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    add_index :investigation_embeddings, :status
    add_index :investigation_embeddings, :content_digest
  end
end
