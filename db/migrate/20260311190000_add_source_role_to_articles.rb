class AddSourceRoleToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :source_role, :string, default: "unknown", null: false
    add_index :articles, :source_role
  end
end
