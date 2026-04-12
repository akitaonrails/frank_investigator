module Analyzers
  # Detects authority laundering: when a low-authority source gets cited by
  # progressively higher-authority outlets until it appears authoritative,
  # without any new primary evidence being added at each step.
  #
  # Example: a blog post makes an unsubstantiated claim → a small news site
  # cites the blog → a major outlet cites the small site → now the claim
  # "has been reported by" the major outlet. At no point did anyone verify
  # the original claim with primary evidence.
  #
  # This is primarily a graph-based heuristic analyzer. The LLM is only
  # invoked for ambiguous chains where the heuristic cannot determine whether
  # genuine new reporting occurred at each step.
  class AuthorityLaunderingDetector
    include LlmHelpers

    AUTHORITY_TIERS_RANKED = %w[unknown low secondary primary].freeze

    Step = Struct.new(:url, :host, :authority_tier, :source_kind, keyword_init: true)

    Chain = Struct.new(
      :steps,
      :originating_authority,
      :final_authority,
      :new_evidence_added,
      :severity,
      :explanation,
      keyword_init: true
    )

    Result = Struct.new(
      :chains,
      :laundering_score,
      :circular_citations_found,
      :summary,
      keyword_init: true
    )

    MAX_CHAIN_DEPTH = 6
    MAX_CHAINS_FOR_LLM = 3

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      You are a media analysis expert for a fact-checking system. Your job is to determine
      whether genuine new reporting or evidence was added at each step of a citation chain,
      or whether a low-authority claim was simply laundered through progressively higher-authority
      outlets without verification.

      Authority laundering occurs when:
      1. A low-authority source makes an unverified claim
      2. A higher-authority outlet cites that source
      3. Even higher outlets then cite the second outlet
      4. The claim now appears authoritative, but no one actually verified it

      Genuine new reporting at a step means the outlet:
      - Contacted the subject of the claim for comment
      - Obtained official records, documents, or data
      - Conducted independent investigation (interviews, FOIA, etc.)
      - Added substantive context from primary sources not in the original

      Simply rewording the original claim, adding editorial commentary, or citing
      "as reported by [previous outlet]" does NOT constitute new evidence.

      You will receive a citation chain with article excerpts at each step.
      For each step, determine whether genuine new evidence was added.

      IMPORTANT: Write explanations and summary in %{locale_name}.


      CRITICAL — NO HALLUCINATION: Only reference URLs, sources, claims, quotes, and data
      that are EXPLICITLY present in the input provided to you. Do not invent, guess, or
      fabricate any URL, source name, statistic, quote, or claim. If you cannot verify
      something from the provided text, mark it as "unverifiable" — never fill in details
      you are unsure about. Every excerpt must be traceable to the provided input.

      Return strict JSON matching the schema.
    PROMPT

    def self.call(investigation:)
      new(investigation:).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      article = @investigation.root_article
      return empty_result unless article

      links = article.sourced_links.includes(:target_article).to_a
      return empty_result if links.empty?

      # Phase 1: Walk the citation graph and find authority-escalating chains
      raw_chains = discover_chains(article, links)
      return empty_result if raw_chains.empty?

      # Detect circular citations within the chain articles
      chain_article_ids = raw_chains.flat_map { |c| c[:article_ids] }.uniq
      circular_count = count_circular_citations(chain_article_ids)

      # Phase 2: Score chains heuristically
      scored_chains = raw_chains.map { |c| score_chain(c) }

      # Phase 3: Optional LLM for ambiguous chains
      ambiguous = scored_chains.select { |c| c.severity == "medium" }
      if ambiguous.any? && llm_available?
        llm_refined = refine_with_llm(ambiguous.first(MAX_CHAINS_FOR_LLM))
        if llm_refined
          scored_chains = scored_chains.map do |chain|
            replacement = llm_refined.find { |r| r.steps == chain.steps }
            replacement || chain
          end
        end
      end

      laundering_score = compute_laundering_score(scored_chains, circular_count)

      Result.new(
        chains: scored_chains,
        laundering_score: laundering_score,
        circular_citations_found: circular_count,
        summary: build_summary(scored_chains, laundering_score, circular_count)
      )
    end

    private

    # ── Phase 1: Graph walking ──

    def discover_chains(root_article, links)
      chains = []

      links.each do |link|
        target = link.target_article
        next unless target&.fetched?

        chain_data = walk_chain(target, [ root_article ], Set.new([ root_article.id ]))
        chain_data.each do |chain|
          # Only flag chains where authority escalates from the origin
          next unless authority_escalates?(chain[:steps])
          chains << chain
        end
      end

      chains
    end

    def walk_chain(article, ancestors, visited)
      return [] if visited.include?(article.id)
      return [] if ancestors.size >= MAX_CHAIN_DEPTH

      visited = visited.dup.add(article.id)
      current_ancestors = ancestors + [ article ]

      steps = current_ancestors.map { |a| step_for(a) }
      article_ids = current_ancestors.map(&:id)

      results = []

      # Record current chain if it has 2+ hops (root + at least 2 cited articles)
      if current_ancestors.size >= 3
        results << { steps: steps, article_ids: article_ids }
      end

      # Continue walking deeper
      article.sourced_links.includes(:target_article).each do |link|
        next_target = link.target_article
        next unless next_target&.fetched?
        next if visited.include?(next_target.id)

        deeper = walk_chain(next_target, current_ancestors, visited)
        results.concat(deeper)
      end

      results
    end

    def step_for(article)
      Step.new(
        url: article.url,
        host: article.host,
        authority_tier: article.authority_tier,
        source_kind: article.source_kind
      )
    end

    def authority_escalates?(steps)
      return false if steps.size < 3

      origin_rank = tier_rank(steps.last.authority_tier)
      final_rank = tier_rank(steps.first.authority_tier)

      # The deepest source (last in chain) should be lower authority than the root
      # which cites it through intermediaries
      origin_rank < final_rank
    end

    def tier_rank(tier)
      AUTHORITY_TIERS_RANKED.index(tier.to_s) || 0
    end

    # ── Circular citation detection within chains ──

    def count_circular_citations(article_ids)
      return 0 if article_ids.size < 2

      id_set = Set.new(article_ids)
      internal_links = ArticleLink
        .where(source_article_id: id_set, target_article_id: id_set)
        .pluck(:source_article_id, :target_article_id)

      link_set = Set.new(internal_links)
      count = 0

      internal_links.each do |source_id, target_id|
        if link_set.include?([ target_id, source_id ]) && source_id < target_id
          count += 1
        end
      end

      count
    end

    # ── Phase 2: Heuristic scoring ──

    def score_chain(chain_data)
      steps = chain_data[:steps]
      origin = steps.last
      final_step = steps.first

      origin_rank = tier_rank(origin.authority_tier)
      final_rank = tier_rank(final_step.authority_tier)
      rank_jump = final_rank - origin_rank

      # Check whether the chain crosses editorial boundaries
      hosts = steps.map(&:host).uniq
      independence_groups = steps.map { |s| independence_group_for(s.host) }.uniq
      crosses_editorial_boundary = independence_groups.size > 1

      # Determine severity based on rank jump and editorial crossing
      severity = if rank_jump >= 2 && crosses_editorial_boundary
        "high"
      elsif rank_jump >= 2 || (rank_jump == 1 && crosses_editorial_boundary)
        "medium"
      else
        "low"
      end

      # Heuristic: if the originating source has no primary-tier evidence,
      # new evidence is unlikely to have been added
      new_evidence = origin.authority_tier == "primary"

      explanation = build_chain_explanation(steps, rank_jump, crosses_editorial_boundary, hosts)

      Chain.new(
        steps: steps,
        originating_authority: origin.authority_tier,
        final_authority: final_step.authority_tier,
        new_evidence_added: new_evidence,
        severity: severity,
        explanation: explanation
      )
    end

    def independence_group_for(host)
      # Delegate to Article's independence_group if available, else use host root
      article = Article.find_by(host: host)
      article&.independence_group || extract_root_domain(host)
    end

    def extract_root_domain(host)
      parts = host.to_s.split(".")
      parts.length >= 2 ? parts.last(2).join(".") : host.to_s
    end

    def build_chain_explanation(steps, rank_jump, crosses_boundary, hosts)
      origin = steps.last
      final_step = steps.first
      hop_count = steps.size - 1

      parts = []
      parts << I18n.t(
        "authority_laundering.chain_explanation.escalation",
        origin_tier: origin.authority_tier,
        origin_host: origin.host,
        final_tier: final_step.authority_tier,
        final_host: final_step.host,
        hops: hop_count,
        default: "Authority escalates from %{origin_tier} (%{origin_host}) to %{final_tier} (%{final_host}) across %{hops} hop(s)"
      )

      if crosses_boundary
        parts << I18n.t(
          "authority_laundering.chain_explanation.crosses_boundary",
          count: hosts.size,
          default: "Chain crosses %{count} editorial boundaries"
        )
      else
        parts << I18n.t(
          "authority_laundering.chain_explanation.same_group",
          default: "Chain stays within the same editorial group"
        )
      end

      parts.join(". ") + "."
    end

    # ── Phase 3: Optional LLM refinement ──

    def refine_with_llm(ambiguous_chains)
      prompt = build_llm_prompt(ambiguous_chains)
      fingerprint = Digest::SHA256.hexdigest(prompt)
      model = primary_model

      if (cached = LlmInteraction.find_cached(evidence_packet_fingerprint: fingerprint, model_id: model))
        return parse_llm_response(cached.response_json&.deep_symbolize_keys, ambiguous_chains)
      end

      interaction = create_interaction(model, prompt, fingerprint)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Timeout.timeout(llm_timeout) do
        llm_chat(model:)
          .with_instructions(system_prompt)
          .with_schema(response_schema)
          .ask(prompt)
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i

      raise "Empty LLM response" if response.content.blank?
      payload = response.content.is_a?(Hash) ? response.content : JSON.parse(unwrap_json(response.content))
      complete_interaction(interaction, response, payload, elapsed_ms)

      parse_llm_response(payload.deep_symbolize_keys, ambiguous_chains)
    rescue StandardError => e
      fail_interaction(interaction, e) if interaction
      Rails.logger.warn("Authority laundering LLM refinement failed: #{e.message}")
      nil
    end

    def build_llm_prompt(chains)
      chain_descriptions = chains.map.with_index do |chain, idx|
        steps_desc = chain.steps.map.with_index do |step, step_idx|
          article = Article.find_by(url: step.url)
          excerpt = article&.body_text.to_s.truncate(500)
          "  Step #{step_idx + 1}: [#{step.authority_tier}] #{step.host} — #{excerpt}"
        end.join("\n")

        "Chain #{idx + 1}:\n#{steps_desc}"
      end.join("\n\n")

      {
        investigation_id: @investigation.id,
        chains: chain_descriptions,
        question: "For each chain, determine whether genuine new reporting or evidence was added at each step beyond the originating source."
      }.to_json
    end

    def response_schema
      {
        name: "authority_laundering_analysis",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            chains: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  chain_index: { type: "integer" },
                  new_evidence_added: { type: "boolean" },
                  severity: { type: "string", enum: %w[low medium high] },
                  explanation: { type: "string" }
                },
                required: %w[chain_index new_evidence_added severity explanation]
              }
            },
            summary: { type: "string" }
          },
          required: %w[chains summary]
        }
      }
    end

    def parse_llm_response(payload, original_chains)
      return nil unless payload && payload[:chains]

      payload[:chains].filter_map do |llm_chain|
        idx = llm_chain[:chain_index].to_i - 1
        original = original_chains[idx]
        next unless original

        Chain.new(
          steps: original.steps,
          originating_authority: original.originating_authority,
          final_authority: original.final_authority,
          new_evidence_added: llm_chain[:new_evidence_added] == true,
          severity: %w[low medium high].include?(llm_chain[:severity]) ? llm_chain[:severity] : original.severity,
          explanation: llm_chain[:explanation].presence || original.explanation
        )
      end
    end

    # ── Scoring ──

    def compute_laundering_score(chains, circular_count)
      return 0.0 if chains.empty?

      severity_weights = { "high" => 0.35, "medium" => 0.2, "low" => 0.08 }

      chain_score = chains.sum { |c| severity_weights.fetch(c.severity, 0.1) }

      # Chains where evidence was genuinely added are less concerning
      evidence_discount = chains.count(&:new_evidence_added) * 0.15
      chain_score -= evidence_discount

      # Circular citations amplify laundering
      circular_bonus = [ circular_count * 0.1, 0.25 ].min

      [ (chain_score + circular_bonus).clamp(0.0, 1.0).round(2), 1.0 ].min
    end

    def build_summary(chains, score, circular_count)
      if chains.empty?
        return I18n.t(
          "authority_laundering.summary.no_chains",
          default: "No authority laundering chains detected. Citations reference sources directly."
        )
      end

      high = chains.count { |c| c.severity == "high" }
      medium = chains.count { |c| c.severity == "medium" }

      I18n.t(
        "authority_laundering.summary.chains_found",
        total: chains.size,
        high: high,
        medium: medium,
        score: score,
        circular: circular_count,
        default: "%{total} citation chain(s) detected with authority escalation (%{high} high, %{medium} medium severity). Laundering score: %{score}. Circular citations: %{circular}."
      )
    end

    def empty_result
      Result.new(
        chains: [],
        laundering_score: 0.0,
        circular_citations_found: 0,
        summary: I18n.t(
          "authority_laundering.summary.no_analysis",
          default: "No multi-hop citation chains found to analyze."
        )
      )
    end

    def interaction_type_name
      :authority_laundering
    end

    def system_prompt
      SYSTEM_PROMPT_TEMPLATE
        .gsub("%{locale_name}", locale_name)
    end
  end
end
