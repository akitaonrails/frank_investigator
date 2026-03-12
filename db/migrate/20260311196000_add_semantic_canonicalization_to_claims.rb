class AddSemanticCanonicalizationToClaims < ActiveRecord::Migration[8.1]
  def change
    add_column :claims, :semantic_key, :string
    add_column :claims, :canonical_form, :text
    add_column :claims, :canonicalization_version, :integer, default: 0, null: false

    add_index :claims, :semantic_key
  end
end
