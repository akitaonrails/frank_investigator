class AddRejectionReasonToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :rejection_reason, :string
  end
end
