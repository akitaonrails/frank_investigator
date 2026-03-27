module Analyzers
  # Cross-references completed investigations about the same event.
  # Builds a composite fact map from all related investigations and
  # annotates each with what it covers vs what it omits.
  #
  # Runs once after an investigation completes. Reads stored data from
  # sibling investigations — no cascading re-analysis, no infinite loops.
  #
  # Finding related investigations:
  # 1. Extract key entities (people, orgs) from the investigation's claims
  # 2. Search other completed investigations for overlapping entities
  # 3. Build composite from all related investigations' claims + gaps
  # 4. For each investigation, compute coverage vs the composite
  class CrossInvestigationEnricher
    include LlmHelpers

    MIN_ENTITY_OVERLAP = 2
    MIN_KEYWORD_OVERLAP = 6
    MAX_RELATED = 10

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are an event analyst for a fact-checking system. You will receive data from
      multiple news articles covering the SAME event, each analyzed independently.

      Your job is to synthesize ALL findings into a composite event picture:

      1. COMPOSITE TIMELINE: What is the full sequence of events, combining facts from
         all articles? Include facts that ANY article reported, even if others omitted them.

      2. FACT COVERAGE MAP: For each article (identified by host), list which key facts
         it includes and which it omits relative to the composite.

      3. OVERALL NARRATIVE ASSESSMENT: Do the articles tell the same story or different
         stories? Is there a dominant framing that most articles share? Does any article
         present facts that contradict the dominant framing?

      4. CRITICAL OMISSIONS: Facts that appear in at least one article but are missing
         from the majority. These are the most important findings — they reveal what
         the dominant narrative suppresses.

      IMPORTANT: Write all text in %{locale_name}.

      CRITICAL — NO HALLUCINATION: Only synthesize facts that are EXPLICITLY present
      in the provided investigation data. Do not add facts from your own knowledge.
      The composite must be built ONLY from what the analyzed articles contain.

      Return strict JSON matching the schema.
    PROMPT

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      related = find_related_investigations
      return nil if related.empty?

      all_investigations = [ @investigation ] + related
      composite = build_composite(all_investigations)
      return nil unless composite

      # Store event context on ALL related investigations (including self)
      event_data = {
        composite_timeline: composite[:composite_timeline],
        critical_omissions: Array(composite[:critical_omissions]),
        narrative_assessment: composite[:narrative_assessment],
        related_investigations: all_investigations.map { |inv|
          coverage = Array(composite[:coverage_map]).find { |c| c[:host] == inv.root_article&.host } || {}
          {
            slug: inv.slug,
            host: inv.root_article&.host,
            title: inv.root_article&.title&.truncate(80),
            quality: inv.llm_summary&.dig("overall_quality"),
            facts_included: Array(coverage[:facts_included]),
            facts_omitted: Array(coverage[:facts_omitted])
          }
        },
        updated_at: Time.current.iso8601
      }

      all_investigations.each do |inv|
        inv.update_column(:event_context, event_data)
      end

      event_data
    end

    private

    def find_related_investigations
      # Extract entity names from this investigation's claims
      entities = extract_entities
      return [] if entities.size < 2

      # Search other completed investigations for overlapping entities
      candidates = Investigation.where(status: "completed")
        .where.not(id: @investigation.id)
        .includes(:root_article, :claim_assessments)
        .limit(50)

      keywords = extract_keywords_from(@investigation)

      related = candidates.select do |inv|
        # Match by entity names (proper nouns)
        other_entities = extract_entities_from(inv)
        entity_overlap = (entities & other_entities).size
        next true if entity_overlap >= MIN_ENTITY_OVERLAP

        # Match by keyword overlap (significant words from claims + title)
        other_keywords = extract_keywords_from(inv)
        keyword_overlap = (keywords & other_keywords).size
        keyword_overlap >= MIN_KEYWORD_OVERLAP
      end

      related.first(MAX_RELATED)
    end

    def extract_entities
      extract_entities_from(@investigation)
    end

    # Stop words to exclude from keyword matching
    STOP_WORDS = Set.new(%w[
      a o e de da do das dos em na no nas nos por para com que se um uma os as ao aos
      the and of to in for is on at by from with this that was were are be been has have
      não foi são ser mais como entre sobre após desde também ainda
    ]).freeze

    def extract_keywords_from(investigation)
      text = [
        investigation.root_article&.title,
        investigation.root_article&.body_text.to_s.truncate(2000),
        investigation.claim_assessments.includes(:claim).map { |ca| ca.claim.canonical_text }
      ].flatten.compact.join(" ")

      text.downcase
        .gsub(/[^a-zà-ú0-9\s]/, " ")
        .split
        .reject { |w| w.length < 5 || STOP_WORDS.include?(w) }
        .uniq
        .to_set
    end

    def extract_entities_from(investigation)
      entities = Set.new

      # From claims
      investigation.claim_assessments.includes(:claim).each do |ca|
        text = ca.claim.canonical_text.to_s
        # Extract capitalized multi-word names (simple NER heuristic)
        text.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each { |name| entities << name.downcase }
        # Extract single capitalized words that are likely proper nouns (>4 chars)
        text.scan(/\b[A-ZÀ-Ú][a-zà-ú]{4,}\b/).each { |name| entities << name.downcase }
      end

      # From article title
      title = investigation.root_article&.title.to_s
      title.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each { |name| entities << name.downcase }

      # From contextual gaps questions (often contain entity names)
      Array(investigation.contextual_gaps&.dig("gaps")).each do |gap|
        q = gap["question"].to_s
        q.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each { |name| entities << name.downcase }
      end

      entities
    end

    def build_composite(investigations)
      return nil unless llm_available?

      prompt_data = investigations.map do |inv|
        {
          host: inv.root_article&.host,
          title: inv.root_article&.title,
          claims: inv.claim_assessments.includes(:claim).map { |ca|
            { text: ca.claim.canonical_text, verdict: ca.verdict, confidence: ca.confidence_score.to_f }
          },
          contextual_gaps: Array(inv.contextual_gaps&.dig("gaps")).map { |g| g["question"] },
          coordination_findings: {
            convergent_framing: Array(inv.coordinated_narrative&.dig("convergent_framing")),
            convergent_omissions: Array(inv.coordinated_narrative&.dig("convergent_omissions"))
          },
          summary_quality: inv.llm_summary&.dig("overall_quality"),
          summary_weaknesses: Array(inv.llm_summary&.dig("weaknesses"))
        }
      end

      prompt = prompt_data.to_json
      fingerprint = Digest::SHA256.hexdigest("cross:#{prompt}")
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return cached.response_json&.deep_symbolize_keys
      end

      interaction = create_interaction(model, prompt, fingerprint)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)
          .with_instructions(system_prompt)
          .with_schema(composite_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      payload.deep_symbolize_keys
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Cross-investigation enrichment failed: #{e.message}")
      nil
    end

    def composite_schema
      {
        name: "cross_investigation_composite",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            composite_timeline: { type: "string", description: "Full event timeline combining facts from all articles" },
            coverage_map: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  host: { type: "string" },
                  facts_included: { type: "array", items: { type: "string" } },
                  facts_omitted: { type: "array", items: { type: "string" } }
                },
                required: %w[host facts_included facts_omitted]
              }
            },
            narrative_assessment: { type: "string" },
            critical_omissions: { type: "array", items: { type: "string" }, description: "Facts in at least one article but missing from majority" }
          },
          required: %w[composite_timeline coverage_map narrative_assessment critical_omissions]
        }
      }
    end

    def interaction_type_name
      :investigation_summary # reuse existing type for cross-ref
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE.gsub("%{locale_name}", locale_name)
    end
  end
end
