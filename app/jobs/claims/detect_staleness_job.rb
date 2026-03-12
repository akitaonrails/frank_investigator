module Claims
  class DetectStalenessJob < ApplicationJob
    queue_as :default

    def perform
      flagged = 0

      ClaimAssessment
        .where.not(verdict: "pending")
        .where(stale_at: nil)
        .includes(:claim)
        .find_each do |assessment|

        result = Analyzers::StalenessDetector.call(assessment)
        next unless result.stale

        assessment.update!(stale_at: Time.current, staleness_reason: result.reason)
        flagged += 1
      end

      Rails.logger.info("[StalenessDetection] Flagged #{flagged} stale assessments")
    end
  end
end
