module Analyzers
  class ClaimFingerprint
    def self.call(text, canonical_form: nil)
      source = canonical_form.presence || text
      Digest::SHA256.hexdigest(TextAnalysis.normalize(source))
    end
  end
end
