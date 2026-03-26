class AddSlugToInvestigations < ActiveRecord::Migration[8.1]
  def change
    add_column :investigations, :slug, :string
    add_index :investigations, :slug, unique: true

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE investigations SET slug = lower(hex(randomblob(5))) WHERE slug IS NULL
        SQL
      end
    end
  end
end
