module Analyzers
  class StalenessDetector
    RECENT_CLAIM_STALE_DAYS = 7
    HISTORICAL_CLAIM_STALE_DAYS = 30
    LOW_CONFIDENCE_STALE_DAYS = 3

    Result = Struct.new(:stale, :reason, :priority, keyword_init: true)

    def self.call(assessment)
      new(assessment).call
    end

    def initialize(assessment)
      @assessment = assessment
      @claim = assessment.claim
    end

    def call
      return not_stale if @assessment.verdict_pending?

      assessed_at = @assessment.assessed_at || @assessment.updated_at

      # Check new evidence first (highest priority)
      if new_evidence_available?
        return Result.new(stale: true, reason: "new_evidence", priority: :high)
      end

      # Low confidence claims reassess sooner
      if @assessment.verdict_needs_more_evidence? && @assessment.confidence_score.to_f < 0.5
        if assessed_at < LOW_CONFIDENCE_STALE_DAYS.days.ago
          return Result.new(stale: true, reason: "low_confidence", priority: :medium)
        end
      end

      # Time-based staleness depends on whether claim references recent events
      stale_days = recent_claim? ? RECENT_CLAIM_STALE_DAYS : HISTORICAL_CLAIM_STALE_DAYS
      if assessed_at < stale_days.days.ago
        return Result.new(stale: true, reason: "time_elapsed", priority: recent_claim? ? :high : :low)
      end

      not_stale
    end

    private

    def new_evidence_available?
      current_count = @claim.article_claims.count
      current_count > @claim.evidence_article_count
    end

    def recent_claim?
      return false unless @claim.claim_timestamp_end.present?
      @claim.claim_timestamp_end >= 6.months.ago.to_date
    end

    def not_stale
      Result.new(stale: false, reason: nil, priority: nil)
    end
  end
end
