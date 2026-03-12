module Claims
  class DetectSourceCorrectionsJob < ApplicationJob
    queue_as :default

    def perform
      result = Analyzers::SourceCorrectionDetector.call
      Rails.logger.info(
        "Source correction detection: #{result.corrected_articles} article(s) changed, " \
        "#{result.affected_assessments} assessment(s) flagged as stale"
      )
    end
  end
end
