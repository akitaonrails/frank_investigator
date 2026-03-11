class AddClaimTimestamps < ActiveRecord::Migration[8.1]
  def change
    add_column :claims, :claim_timestamp_start, :date
    add_column :claims, :claim_timestamp_end, :date
  end
end
