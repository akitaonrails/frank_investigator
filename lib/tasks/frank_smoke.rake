namespace :frank do
  desc "Smoke test the OpenRouter-backed RubyLLM client"
  task smoke_openrouter: :environment do
    claim = Struct.new(:canonical_text, :checkability_status).new(
      "The budget report confirms a 4 percent tax reduction in 2026.",
      "checkable"
    )

    evidence_packet = [
      {
        url: "https://www.sec.gov/reports/budget-filing",
        title: "Budget report confirms a 4 percent tax reduction in 2026",
        excerpt: "The budget report confirms a 4 percent tax reduction in 2026.",
        stance: "supports",
        relevance_score: 0.98,
        authority_score: 0.98,
        authority_tier: "primary",
        source_kind: "government_record",
        independence_group: "sec.gov"
      }
    ]

    model = ENV.fetch("FRANK_SMOKE_MODEL", Rails.application.config.x.frank_investigator.openrouter_models.first)
    client = Llm::RubyLlmClient.new(models: [model])

    abort "OPENROUTER_API_KEY is not configured" unless client.available?

    result = client.call(claim:, evidence_packet:)

    puts JSON.pretty_generate(
      model:,
      verdict: result.verdict,
      confidence_score: result.confidence_score,
      reason_summary: result.reason_summary
    )
  end

  desc "Smoke test Chromium fetch and extraction for a URL"
  task :smoke_fetch, [:url] => :environment do |_, args|
    url = args[:url].presence || "https://example.com"
    snapshot = Fetchers::ChromiumFetcher.call(url)
    extracted = Parsing::MainContentExtractor.call(html: snapshot.html, url:)

    puts JSON.pretty_generate(
      url:,
      title: extracted.title,
      main_content_path: extracted.main_content_path,
      excerpt: extracted.excerpt,
      links_count: extracted.links.count
    )
  end
end
