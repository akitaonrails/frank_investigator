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
      fingerprint = Analyzers::ClaimFingerprint.call(decomposed.canonical_text)

      existing = Claim.find_by(canonical_fingerprint: fingerprint)
      if existing
        existing.update!(last_seen_at: Time.current)
        return existing
      end

      matches = Analyzers::ClaimSimilarityMatcher.call(
        text: decomposed.canonical_text,
        candidates: Claim.where(checkability_status: decomposed.checkability_status)
      )

      if matches.any? && matches.first.similarity_score >= 0.7
        matched_claim = matches.first.claim
        matched_claim.update!(last_seen_at: Time.current)
        return matched_claim
      end

      Claim.create!(
        canonical_text: decomposed.canonical_text,
        canonical_fingerprint: fingerprint,
        checkability_status: decomposed.checkability_status || result.checkability_status,
        claim_kind: decomposed.claim_kind || :statement,
        entities_json: decomposed.entities || {},
        time_scope: decomposed.time_scope,
        claim_timestamp_start: decomposed.claim_timestamp_start,
        claim_timestamp_end: decomposed.claim_timestamp_end,
        first_seen_at: Time.current,
        last_seen_at: Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      Claim.find_by!(canonical_fingerprint: Analyzers::ClaimFingerprint.call(decomposed.canonical_text))
    end

    def upsert_article_claim!(claim, result)
      ArticleClaim.find_or_create_by!(article: @article, claim:, role: result.role) do |record|
        record.surface_text = result.surface_text
        record.importance_score = result.importance_score
        record.title_related = result.role.to_s == "headline"
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
