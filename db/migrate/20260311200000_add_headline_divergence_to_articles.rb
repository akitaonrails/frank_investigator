class AddHeadlineDivergenceToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :headline_divergence_score, :decimal, precision: 5, scale: 2
  end
end
