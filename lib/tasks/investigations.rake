namespace :frank do
  desc "Re-run analysis pipeline for an investigation (by slug)"
  task :reanalyze, [ :slug ] => :environment do |_t, args|
    slug = args[:slug] || ENV["SLUG"]
    abort "Usage: rails frank:reanalyze[SLUG] or SLUG=xxx rails frank:reanalyze" unless slug

    inv = Investigation.find_by!(slug: slug)
    puts "Re-analyzing investigation #{inv.slug} (#{inv.normalized_url.truncate(60)})"

    # Clear cached LLM interactions so fresh calls are made
    LlmInteraction.where(investigation: inv).destroy_all
    puts "  Cleared #{LlmInteraction.where(investigation: inv).count} LLM interactions"

    # Reset analysis columns
    inv.update!(
      source_misrepresentation: nil, temporal_manipulation: nil,
      statistical_deception: nil, selective_quotation: nil,
      authority_laundering: nil, rhetorical_analysis: nil,
      contextual_gaps: nil, coordinated_narrative: nil,
      emotional_manipulation: nil, llm_summary: nil,
      headline_bait_score: 0
    )

    # Reset analysis pipeline steps (keep fetch/extract/assess)
    analysis_steps = %w[
      analyze_headline detect_source_misrepresentation detect_temporal_manipulation
      detect_statistical_deception detect_selective_quotation detect_authority_laundering
      analyze_rhetorical_structure analyze_contextual_gaps detect_coordinated_narrative
      score_emotional_manipulation generate_summary
    ]
    inv.pipeline_steps.where(name: analysis_steps).destroy_all
    inv.update!(status: :processing)

    puts "  Reset analysis steps. Re-running from headline analysis..."
    Investigations::AnalyzeHeadlineJob.perform_later(inv.id)
    Investigations::BatchContentAnalysisJob.perform_later(inv.id)
    puts "  Jobs enqueued. Pipeline will complete via Solid Queue."
  end

  desc "Generate honest headlines for all completed investigations"
  task honest_headlines: :environment do
    investigations = Investigation.where(status: "completed").where(honest_headline: nil).includes(:root_article)
    puts "Generating honest headlines for #{investigations.count} investigations..."

    investigations.each do |inv|
      next unless inv.root_article&.title.present?
      honest = Analyzers::HonestHeadlineGenerator.call(investigation: inv)
      if honest
        inv.update_column(:honest_headline, honest)
        puts "  #{inv.slug} — #{honest.truncate(80)}"
      end
    rescue StandardError => e
      puts "  #{inv.slug} — ERROR: #{e.message.truncate(80)}"
    end

    puts "Done."
  end

  desc "Cross-reference ALL completed investigations"
  task crossref_all: :environment do
    investigations = Investigation.where(status: "completed").order(created_at: :desc)
    puts "Cross-referencing #{investigations.count} completed investigations..."

    investigations.each do |inv|
      result = Analyzers::CrossInvestigationEnricher.call(investigation: inv)
      if result
        related = Array(result[:related_investigations])
        puts "  #{inv.slug} — #{related.size} related" if related.size > 1
      end
    rescue StandardError => e
      puts "  #{inv.slug} — ERROR: #{e.message.truncate(80)}"
    end

    puts "Done."
  end

  desc "Backfill vector embeddings for completed investigations"
  task :index_embeddings, [ :limit ] => :environment do |_t, args|
    limit = (args[:limit] || ENV["LIMIT"] || 250).to_i
    model_id = Rails.configuration.x.frank_investigator.embedding_model
    dimensions = Rails.configuration.x.frank_investigator.embedding_dimensions
    scope = Investigation.where(status: "completed")
      .left_outer_joins(:investigation_embedding)
      .where(
        <<~SQL.squish,
          investigation_embeddings.id IS NULL OR
          investigation_embeddings.status != ? OR
          investigation_embeddings.model_id != ? OR
          investigation_embeddings.dimensions != ?
        SQL
        InvestigationEmbedding.statuses[:indexed],
        model_id,
        dimensions
      )
      .distinct
      .order(updated_at: :desc)
    investigations = scope.includes(:root_article, claim_assessments: :claim).limit(limit)

    puts "Indexing embeddings for up to #{investigations.size} completed investigations..."

    investigations.each do |inv|
      record = Investigations::EmbeddingIndexer.call(investigation: inv)
      status = record&.status || "skipped"
      puts "  #{inv.slug} — #{status}"
    rescue StandardError => e
      puts "  #{inv.slug} — ERROR: #{e.class}: #{e.message.truncate(120)}"
    end

    remaining = scope.count
    puts "Remaining investigations still needing indexing: #{remaining}"
    puts "Done."
  end

  desc "Cross-reference an investigation with related ones (by slug)"
  task :crossref, [ :slug ] => :environment do |_t, args|
    slug = args[:slug] || ENV["SLUG"]
    abort "Usage: rails frank:crossref[SLUG]" unless slug

    inv = Investigation.find_by!(slug: slug)
    puts "Cross-referencing #{inv.slug} (#{inv.root_article&.title.to_s.truncate(60)})"

    result = Analyzers::CrossInvestigationEnricher.call(investigation: inv)
    if result
      related = Array(result[:related_investigations])
      puts "  Found #{related.size} related investigations"
      related.each { |r| puts "    #{r[:slug]} — #{r[:host]} (#{r[:quality]})" }
      puts "  Critical omissions: #{Array(result[:critical_omissions]).size}"
      Array(result[:critical_omissions]).each { |o| puts "    - #{o.truncate(100)}" }
    else
      puts "  No related investigations found."
    end
  end

  desc "Refresh an investigation from stored snapshots and rebuild the pipeline (by slug)"
  task :refresh, [ :slug ] => :environment do |_t, args|
    slug = args[:slug] || ENV["SLUG"]
    abort "Usage: rails frank:refresh[SLUG]" unless slug

    inv = Investigation.find_by!(slug: slug)
    puts "Refreshing #{inv.slug} (#{inv.root_article&.title.to_s.truncate(60)}) from stored content..."

    Investigations::RefreshFromSnapshots.call(investigation: inv)

    inv.reload
    puts "  Status: #{inv.status}"
    puts "  Claims: #{inv.claim_assessments.count}"
    puts "  Event context: #{inv.event_context.present? ? 'present' : 'absent'}"
  end
end
