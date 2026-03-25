class AddLlmSummaryToInvestigations < ActiveRecord::Migration[8.1]
  def change
    add_column :investigations, :llm_summary, :json
  end
end
