class CreateMediaOwnershipGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :media_ownership_groups do |t|
      t.string :name, null: false
      t.string :parent_company
      t.json :owned_hosts, default: [], null: false
      t.json :owned_independence_groups, default: [], null: false
      t.string :country
      t.text :notes
      t.timestamps
    end

    add_index :media_ownership_groups, :name, unique: true
  end
end
