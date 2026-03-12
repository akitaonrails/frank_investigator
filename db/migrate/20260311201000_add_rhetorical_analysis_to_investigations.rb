class AddRhetoricalAnalysisToInvestigations < ActiveRecord::Migration[8.1]
  def change
    add_column :investigations, :rhetorical_analysis, :json
  end
end
