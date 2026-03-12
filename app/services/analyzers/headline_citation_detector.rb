module Analyzers
  # Detects when articles cite another article's sensational headline
  # rather than its actual body findings.
  #
  # Pattern: Article A has headline "Celebrity X caught in scandal" but body says
  # "neighbors claim they heard screaming, no police report filed". Article B
  # then writes "As reported by [A], Celebrity X was caught in scandal" — citing
  # the headline, not the hedged body. Article B amplifies a claim that A's own
  # body doesn't substantiate.
  #
  # This is a key mechanism in smear campaigns: one outlet writes a baiting
  # headline, others cite the headline as if it were established fact.
  class HeadlineCitationDetector
    Result = Struct.new(:headline_citations, :amplification_score, keyword_init: true)

    HeadlineCitation = Struct.new(:citing_article_id, :cited_article_id,
                                  :headline_match_ratio, :body_match_ratio,
                                  keyword_init: true)

    # Minimum headline token overlap to consider it a headline citation
    HEADLINE_MATCH_THRESHOLD = 0.6
    # If body match is below this while headline match is high, it's headline-only citing
    BODY_MATCH_CEILING = 0.15

    def self.call(articles:)
      new(articles:).call
    end

    def initialize(articles:)
      @articles = articles.select { |a| a.title.present? && a.body_text.present? }
    end

    def call
      citations = detect_headline_citations
      Result.new(
        headline_citations: citations,
        amplification_score: compute_amplification_score(citations)
      )
    end

    private

    def detect_headline_citations
      citations = []

      @articles.combination(2).each do |art_a, art_b|
        # Check if B's body contains A's headline but not A's body qualifiers
        citation = check_headline_citation(citing: art_b, cited: art_a)
        citations << citation if citation

        # Check the reverse
        citation = check_headline_citation(citing: art_a, cited: art_b)
        citations << citation if citation
      end

      citations
    end

    def check_headline_citation(citing:, cited:)
      cited_headline_tokens = significant_tokens(cited.title)
      return nil if cited_headline_tokens.size < 3

      citing_body_tokens = significant_tokens(citing.body_text)
      return nil if citing_body_tokens.empty?

      # How much of the cited headline appears in the citing article's body?
      headline_overlap = (cited_headline_tokens & citing_body_tokens).size.to_f / cited_headline_tokens.size
      return nil if headline_overlap < HEADLINE_MATCH_THRESHOLD

      # How much of the cited article's BODY qualifying content appears in the citing article?
      # We extract the hedging/qualifying phrases from the cited body and check overlap
      cited_body_qualifying = qualifying_tokens(cited.body_text)
      if cited_body_qualifying.any?
        body_overlap = (cited_body_qualifying & citing_body_tokens).size.to_f / cited_body_qualifying.size
      else
        # No qualifying language in cited body — not a bait pattern
        return nil
      end

      # Headline-only citation: high headline overlap, low body qualifier overlap
      return nil if body_overlap > BODY_MATCH_CEILING

      HeadlineCitation.new(
        citing_article_id: citing.id,
        cited_article_id: cited.id,
        headline_match_ratio: headline_overlap.round(2),
        body_match_ratio: body_overlap.round(2)
      )
    end

    # Tokens that carry meaning (skip stop words and very short tokens)
    def significant_tokens(text)
      TextAnalysis.simple_tokens(text.to_s)
        .reject { |t| t.length < 3 || TextAnalysis::STOP_WORDS.include?(t) }
        .uniq
    end

    # Extract tokens from hedging/qualifying sentences in the body
    def qualifying_tokens(body_text)
      qualifying_sentences = body_text.to_s.split(/[.!?\n]/).select do |sentence|
        HeadlineBaitAnalyzer::HEDGING_PATTERNS.any? { |p| sentence.match?(p) }
      end

      qualifying_sentences.flat_map { |s| significant_tokens(s) }.uniq
    end

    def compute_amplification_score(citations)
      return 0.0 if citations.empty?

      # Each headline-only citation amplifies misinformation
      # More citations = worse; cap at 1.0
      [citations.size * 0.25, 1.0].min.round(2)
    end
  end
end
