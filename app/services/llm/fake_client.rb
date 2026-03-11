module Llm
  class FakeClient
    Result = Struct.new(:verdict, :confidence_score, :reason_summary, keyword_init: true)

    class << self
      attr_accessor :next_result
    end

    def available?
      self.class.next_result.present?
    end

    def call(claim:, evidence_packet:)
      self.class.next_result || Result.new(
        verdict: "needs_more_evidence",
        confidence_score: 0.41,
        reason_summary: "Fake client placeholder response."
      )
    end
  end
end
