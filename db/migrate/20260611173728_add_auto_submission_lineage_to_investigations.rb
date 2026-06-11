class AddAutoSubmissionLineageToInvestigations < ActiveRecord::Migration[8.1]
  def change
    change_table :investigations do |t|
      # Self-reference: which investigation auto-submitted this one as related?
      t.integer :auto_submitted_from_id
      t.index :auto_submitted_from_id

      # Last time enrichment-stage outputs (event_context, honest_headline) were
      # re-generated for this investigation after auto-submitted children completed.
      # Used by RefreshParentEnrichmentJob to no-op when no new child data exists.
      t.datetime :last_enrichment_refresh_at
    end
  end
end
