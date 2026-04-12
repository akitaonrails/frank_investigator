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

    MAX_CANDIDATES = 300
    MIN_ENTITY_OVERLAP = 2
    MIN_TOPIC_OVERLAP = 2
    MIN_SUBJECT_TOPIC_OVERLAP = 4
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
      primary_subjects = extract_primary_subjects_from(@investigation)
      anchor_subjects = extract_anchor_subjects_from(@investigation)
      fallback_entities = extract_entities
      return [] if primary_subjects.empty? && anchor_subjects.empty? && fallback_entities.empty?

      heuristic_candidates = Investigation.where(status: "completed")
        .where.not(id: @investigation.id)
        .includes(:root_article, :claim_assessments)
        .order(updated_at: :desc)
        .limit(MAX_CANDIDATES)
        .to_a
      vector_candidates = Investigations::VectorCandidateRetriever.call(
        investigation: @investigation,
        limit: MAX_CANDIDATES
      )
      vector_ranks = vector_candidates.each_with_index.to_h { |investigation, index| [ investigation.id, index ] }
      candidates = merge_candidates(vector_candidates, heuristic_candidates)

      topics = extract_topics_from(@investigation)
      subject_topic_tokens = extract_subject_topic_tokens_from(@investigation)

      related = candidates.filter_map do |inv|
        score = relatedness_score(
          investigation: inv,
          primary_subjects:,
          anchor_subjects:,
          fallback_entities:,
          topics:,
          subject_topic_tokens:
        )
        next unless score

        [ inv, score + vector_boost_for(inv.id, vector_ranks) ]
      end.compact

      related
        .sort_by { |(_inv, score)| -score }
        .map(&:first)
        .first(MAX_RELATED)
    end

    def merge_candidates(vector_candidates, heuristic_candidates)
      seen_ids = Set.new

      (vector_candidates + heuristic_candidates).each_with_object([]) do |investigation, merged|
        next if seen_ids.include?(investigation.id)

        seen_ids << investigation.id
        merged << investigation
      end
    end

    def relatedness_score(investigation:, primary_subjects:, anchor_subjects:, fallback_entities:, topics:, subject_topic_tokens:)
      other_primary_subjects = extract_primary_subjects_from(investigation)
      other_anchor_subjects = extract_anchor_subjects_from(investigation)
      other_topics = extract_topics_from(investigation)
      topic_overlap = (topics & other_topics)

      score =
        primary_overlap = (primary_subjects & other_primary_subjects).size
        if primary_overlap.positive?
          primary_overlap * 100
        elsif anchor_subjects.present? && other_anchor_subjects.present?
          anchor_overlap = (anchor_subjects & other_anchor_subjects).size
          return unless anchor_overlap.positive?

          anchor_overlap * 70
        elsif subject_topic_tokens.any? && (subject_topic_tokens & topic_overlap).any? &&
            topic_overlap.size >= MIN_SUBJECT_TOPIC_OVERLAP
          40 + topic_overlap.size
        else
          other_entities = extract_entities_from(investigation)
          entity_overlap = (fallback_entities & other_entities).size
          return unless entity_overlap >= MIN_ENTITY_OVERLAP

          entity_overlap * 100
        end

      return unless topic_overlap.size >= MIN_TOPIC_OVERLAP

      score + topic_overlap.size
    end

    def vector_boost_for(investigation_id, vector_ranks)
      rank = vector_ranks[investigation_id]
      return 0 unless rank

      [ 25 - rank, 5 ].max
    end

    def extract_entities
      extract_entities_from(@investigation)
    end

    def extract_primary_subjects_from(investigation)
      title = investigation.root_article&.title.to_s
      subjects = Set.new

      title.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each do |name|
        subjects << name.downcase
      end

      title.scan(/\b[A-ZÀ-Ú][a-zà-ú]{4,}\b/).each do |name|
        normalized = name.downcase
        next if GENERIC_ENTITY_TOKENS.include?(normalized)

        subjects << normalized
      end

      subjects
    end

    def extract_anchor_subjects_from(investigation)
      primary_subjects = extract_primary_subjects_from(investigation)
      subject_counts = named_subject_counts_for(investigation)
      anchors = Set.new(primary_subjects)

      subject_counts.each do |subject, count|
        next if count < 2

        anchors << subject
      end

      anchors
    end

    def extract_subject_topic_tokens_from(investigation)
      extract_anchor_subjects_from(investigation)
        .flat_map { |subject| extract_keywords_from_text(subject).to_a }
        .to_set
    end

    # Stop words to exclude from keyword matching
    STOP_WORDS = Set.new(%w[
      a o e de da do das dos em na no nas nos por para com que se um uma os as ao aos
      the and of to in for is on at by from with this that was were are be been has have
      não foi são ser mais como entre sobre após desde também ainda
      acordo artigo Brasil brasileiro casos contra deve disse durante
      estado federal governo havia outra outro parte pode podem
      quando primeiro segundo seria sobre todos vezes
      according article been could during every first government
      other should since their those through would years
    ]).freeze

    GENERIC_ENTITY_TOKENS = Set.new(%w[
      brasil brasileira brasileiro brasileiras brasileiros
      governo federal estadual municipal ministerio ministério camara câmara senado
      prefeitura assembleia tribunal corte justiça congresso policia polícia
      globo globonews folha uol bbc cnn veja estadao estadão poder360 g1
      artigo reportagem coluna colunista editorial portal jornal jornais
    ]).freeze

    def extract_topics_from(investigation)
      extract_keywords_from_text(cross_reference_text_for(investigation))
    end

    STEM_SUFFIXES = %w[
      amentos amento imentos imento ciones coes ções ção cao dade dades mente ismo ismos
      ista istas tico tica ticos ticas ivel iveis ario arios aria arias al ais os as es s
    ].freeze

    def keyword_stem(token)
      stem = token.to_s
      STEM_SUFFIXES.each do |suffix|
        next unless stem.length > suffix.length + 3
        next unless stem.end_with?(suffix)

        stem = stem.delete_suffix(suffix)
        break
      end
      stem[0, 7]
    end

    def extract_keywords_from_text(text)
      Analyzers::TextAnalysis.normalize(text)
        .split
        .map { |token| keyword_stem(token) }
        .reject { |w| w.length < 4 || STOP_WORDS.include?(w) }
        .uniq
        .to_set
    end

    def cross_reference_text_for(investigation)
      [
        investigation.root_article&.title,
        investigation.root_article&.body_text.to_s.truncate(2000),
        investigation.claim_assessments.includes(:claim).map { |ca| ca.claim.canonical_text },
        Array(investigation.contextual_gaps&.dig("gaps")).map { |gap| gap["question"] }
      ].flatten.compact.join(" ")
    end

    def extract_entities_from(investigation)
      entities = Set.new
      single_word_counts = Hash.new(0)

      # From claims
      investigation.claim_assessments.includes(:claim).each do |ca|
        text = ca.claim.canonical_text.to_s
        # Extract capitalized multi-word names (simple NER heuristic)
        text.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each { |name| entities << name.downcase }
        count_single_word_entities(text, single_word_counts)
      end

      # From article title
      title = investigation.root_article&.title.to_s
      title.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each { |name| entities << name.downcase }
      count_single_word_entities(title, single_word_counts)

      # From contextual gaps questions (often contain entity names)
      Array(investigation.contextual_gaps&.dig("gaps")).each do |gap|
        q = gap["question"].to_s
        q.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each { |name| entities << name.downcase }
        count_single_word_entities(q, single_word_counts)
      end

      single_word_counts.each do |name, count|
        next if count < 2
        next if GENERIC_ENTITY_TOKENS.include?(name)

        entities << name
      end

      entities
    end

    def named_subject_counts_for(investigation)
      counts = Hash.new(0)

      investigation.claim_assessments.includes(:claim).each do |ca|
        count_named_subjects(ca.claim.canonical_text.to_s, counts)
      end

      count_named_subjects(investigation.root_article&.title.to_s, counts)

      Array(investigation.contextual_gaps&.dig("gaps")).each do |gap|
        count_named_subjects(gap["question"].to_s, counts)
      end

      counts
    end

    def count_named_subjects(text, counts)
      text.to_s.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each do |name|
        counts[name.downcase] += 1
      end

      text.to_s.scan(/\b[A-ZÀ-Ú][a-zà-ú]{4,}\b/).each do |name|
        normalized = name.downcase
        next if GENERIC_ENTITY_TOKENS.include?(normalized)

        counts[normalized] += 1
      end
    end

    def count_single_word_entities(text, counts)
      text.to_s.scan(/\b[A-ZÀ-Ú][a-zà-ú]{4,}\b/).each do |name|
        counts[name.downcase] += 1
      end
    end

    def build_composite(investigations)
      return heuristic_composite(investigations) unless llm_available?

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
      heuristic_composite(investigations)
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

    def heuristic_composite(investigations)
      facts_by_investigation = investigations.to_h do |inv|
        [ inv, normalized_claims_for(inv) ]
      end

      all_facts = facts_by_investigation.values.flatten.uniq
      return nil if all_facts.empty?

      majority_threshold = (investigations.size / 2) + 1
      critical_omissions = all_facts.select do |fact|
        facts_by_investigation.values.count { |facts| facts.include?(fact) } < majority_threshold
      end

      {
        composite_timeline: heuristic_timeline(all_facts),
        coverage_map: investigations.map { |inv|
          facts = facts_by_investigation.fetch(inv)
          {
            host: inv.root_article&.host,
            facts_included: facts,
            facts_omitted: critical_omissions - facts
          }
        },
        narrative_assessment: heuristic_narrative_assessment(critical_omissions),
        critical_omissions:
      }
    end

    def normalized_claims_for(investigation)
      investigation.claim_assessments.includes(:claim)
        .reject { |assessment| assessment.claim.not_checkable? || assessment.verdict_pending? }
        .map { |assessment| assessment.claim.canonical_text.to_s.squish }
        .reject(&:blank?)
        .uniq
    end

    def heuristic_timeline(facts)
      I18n.t(
        "heuristic_fallbacks.cross_investigation.composite_timeline",
        default: "Heuristic composite from related investigations: %{facts}",
        facts: facts.first(8).join(" | ")
      )
    end

    def heuristic_narrative_assessment(critical_omissions)
      key = critical_omissions.any? ? "divergent" : "aligned"
      I18n.t(
        "heuristic_fallbacks.cross_investigation.narrative_assessment.#{key}",
        default: key == "divergent" ? "Related investigations cover overlapping facts but omit different details." : "Related investigations broadly cover the same factual core."
      )
    end
  end
end
