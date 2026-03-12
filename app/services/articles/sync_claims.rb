module Articles
  class SyncClaims
    def self.call(investigation:, article:)
      new(investigation:, article:).call
    end

    def initialize(investigation:, article:)
      @investigation = investigation
      @article = article
    end

    def call
      Analyzers::ClaimExtractor.call(@article, investigation: @investigation).each do |result|
        decomposed_claims = Analyzers::ClaimDecomposer.call(text: result.canonical_text, investigation: @investigation)

        decomposed_claims.each do |decomposed|
          claim = find_or_create_claim(decomposed, result)
          upsert_article_claim!(claim, result)
          upsert_claim_assessment!(claim)
        end
      end
    end

    private

    def find_or_create_claim(decomposed, result)
      # Canonicalize: use LLM-provided canonical_form if available, else call canonicalizer
      canon = resolve_canonical(decomposed, result)
      fingerprint = Analyzers::ClaimFingerprint.call(decomposed.canonical_text, canonical_form: canon.canonical_form)

      # Stage 1: exact fingerprint match
      existing = Claim.find_by(canonical_fingerprint: fingerprint)
      if existing
        existing.update!(last_seen_at: Time.current)
        backfill_canonical!(existing, canon)
        return existing
      end

      # Stage 2: exact semantic_key match
      if canon.semantic_key.present?
        key_match = Claim.find_by(semantic_key: canon.semantic_key)
        if key_match
          key_match.update!(last_seen_at: Time.current)
          return key_match
        end
      end

      # Stage 3: similarity-based match with entity overlap + optional LLM equivalence
      matches = Analyzers::ClaimSimilarityMatcher.call(
        text: canon.canonical_form,
        candidates: Claim.where(checkability_status: decomposed.checkability_status),
        use_llm: true,
        investigation: @investigation
      )

      if matches.any? && matches.first.similarity_score >= 0.7
        matched_claim = matches.first.claim
        matched_claim.update!(last_seen_at: Time.current)
        return matched_claim
      end

      # Stage 3b: variant detection — moderate similarity (0.5-0.7) means this
      # is likely a mutation of an existing claim (paraphrase, slight rewording).
      # Link it as a variant so prior assessment history is inherited as context.
      variant_parent = if matches.any? && matches.first.similarity_score >= 0.5
        matches.first.claim
      end

      # Stage 4: create new claim
      Claim.create!(
        canonical_text: decomposed.canonical_text,
        canonical_fingerprint: fingerprint,
        canonical_form: canon.canonical_form,
        semantic_key: canon.semantic_key,
        canonicalization_version: Analyzers::ClaimCanonicalizer::CANONICALIZATION_VERSION,
        checkability_status: decomposed.checkability_status || result.checkability_status,
        claim_kind: decomposed.claim_kind || :statement,
        entities_json: decomposed.entities || {},
        time_scope: decomposed.time_scope,
        claim_timestamp_start: decomposed.claim_timestamp_start,
        claim_timestamp_end: decomposed.claim_timestamp_end,
        first_seen_at: Time.current,
        last_seen_at: Time.current,
        canonical_parent: variant_parent,
        variant_of_fingerprint: variant_parent&.canonical_fingerprint
      )
    rescue ActiveRecord::RecordNotUnique
      Claim.find_by!(canonical_fingerprint: fingerprint)
    end

    def resolve_canonical(decomposed, result)
      # Prefer LLM-provided values from the extraction step (no extra LLM call)
      if result.respond_to?(:canonical_form) && result.canonical_form.present? && result.semantic_key.present?
        Analyzers::ClaimCanonicalizer::Result.new(
          canonical_form: result.canonical_form,
          semantic_key: result.semantic_key
        )
      else
        # Fallback: call canonicalizer (for heuristic-extracted claims)
        Analyzers::ClaimCanonicalizer.call(
          text: decomposed.canonical_text,
          entities: decomposed.entities,
          time_scope: decomposed.time_scope
        )
      end
    end

    def backfill_canonical!(claim, canon)
      return if claim.canonical_form.present?

      claim.update!(
        canonical_form: canon.canonical_form,
        semantic_key: canon.semantic_key,
        canonicalization_version: Analyzers::ClaimCanonicalizer::CANONICALIZATION_VERSION
      )
    end

    def upsert_article_claim!(claim, result)
      is_new = !ArticleClaim.exists?(article: @article, claim:, role: result.role)

      ArticleClaim.find_or_create_by!(article: @article, claim:, role: result.role) do |record|
        record.surface_text = result.surface_text
        record.importance_score = result.importance_score
        record.title_related = result.role.to_s == "headline"
      end

      # Flag existing assessments as stale when new evidence links appear
      if is_new
        claim.claim_assessments
          .where(stale_at: nil)
          .where.not(verdict: "pending")
          .where.not(investigation: @investigation)
          .update_all(stale_at: Time.current, staleness_reason: "new_evidence")
      end
    rescue ActiveRecord::RecordNotUnique
      ArticleClaim.find_by!(article: @article, claim:, role: result.role)
    end

    def upsert_claim_assessment!(claim)
      ClaimAssessment.find_or_create_by!(investigation: @investigation, claim:)
    rescue ActiveRecord::RecordNotUnique
      ClaimAssessment.find_by!(investigation: @investigation, claim:)
    end
  end
end
