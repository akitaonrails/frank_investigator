module Analyzers
  class ClaimFingerprint
    def self.call(text)
      TextAnalysis.normalize(text)
    end
  end
end
