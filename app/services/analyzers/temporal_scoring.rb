module Analyzers
  module TemporalScoring
    module_function

    # Scores evidence timeliness relative to a claim's time range.
    # Returns a score between 0.0 and 1.0.
    #
    # - before or during claim range: 0.9 (ideal corroboration window)
    # - within 30 days after: 0.5 (plausible follow-up)
    # - far after (>30 days): 0.2 (stale)
    # - no evidence date: 0.15
    def score(evidence_date, claim_range)
      return 0.15 if evidence_date.nil?
      return 0.15 if claim_range.nil?

      evidence_date = evidence_date.to_date

      if evidence_date <= claim_range.last
        0.9
      elsif evidence_date <= claim_range.last + 30
        0.5
      else
        0.2
      end
    end
  end
end
