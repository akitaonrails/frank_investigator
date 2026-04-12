require "set"

module Investigations
  class IdentitySignals
    MAX_CENTRAL_CLAIMS = 5
    MAX_RELEVANT_GAPS = 4
    MAX_LEAD_SENTENCES = 2

    GENERIC_ENTITY_TOKENS = Set.new(%w[
      brasil brasileira brasileiro brasileiras brasileiros
      governo federal estadual municipal ministerio ministério camara câmara senado
      prefeitura assembleia tribunal corte justiça congresso policia polícia
      globo globonews folha uol bbc cnn veja estadao estadão poder360 g1
      artigo reportagem coluna colunista editorial portal jornal jornais
    ]).freeze

    ROLE_PRIORITY = {
      "headline" => 0,
      "lead" => 1,
      "body" => 2,
      "supporting" => 3,
      "linked_source" => 4
    }.freeze

    def initialize(investigation)
      @investigation = investigation
    end

    def title
      root_article&.title.to_s.squish
    end

    def host
      root_article&.host.to_s.squish
    end

    def lead_text
      @lead_text ||= begin
        body = root_article&.body_text.to_s.squish
        if body.blank?
          ""
        else
          sentences = body.split(/(?<=[.!?])\s+/)
          selected = sentences.select { |sentence| lead_sentence?(sentence) }
          selected = sentences.first(1) if selected.empty?
          selected.first(MAX_LEAD_SENTENCES).join(" ").squish
        end
      end
    end

    def primary_subjects
      @primary_subjects ||= begin
        subjects = Set.new

        title.scan(/\b[A-ZÀ-Ú][a-zà-ú]+(?:\s+[A-ZÀ-Ú][a-zà-ú]+)+\b/).each do |name|
          subjects << name.downcase
        end

        title.scan(/\b[A-ZÀ-Ú][a-zà-ú]{4,}\b/).each do |name|
          normalized = name.downcase
          next if GENERIC_ENTITY_TOKENS.include?(normalized)

          subjects << normalized
        end

        subjects
      end
    end

    def primary_subject_tokens
      @primary_subject_tokens ||= primary_subjects.flat_map { |subject| normalized_tokens_for(subject).to_a }.to_set
    end

    def central_claim_records
      @central_claim_records ||= begin
        claims = root_article&.article_claims&.includes(:claim)&.to_a || []
        ordered_claims = claims.sort_by { |record| claim_rank_for(record) }

        selected = ordered_claims.select { |record| central_claim?(record) }
        selected = ordered_claims.first(3) if selected.empty?
        selected.first(MAX_CENTRAL_CLAIMS)
      end
    end

    def central_claim_texts
      @central_claim_texts ||= begin
        texts = central_claim_records.filter_map { |record| record.claim&.canonical_text.to_s.squish.presence }.uniq
        texts = fallback_claim_texts if texts.empty?
        texts.first(MAX_CENTRAL_CLAIMS)
      end
    end

    def relevant_gap_questions
      @relevant_gap_questions ||= begin
        questions = Array(@investigation.contextual_gaps&.dig("gaps"))
          .filter_map { |gap| gap["question"].to_s.squish.presence }

        selected = questions.select { |question| gap_relevant?(question) }
        selected = questions.first(2) if selected.empty?
        selected.first(MAX_RELEVANT_GAPS)
      end
    end

    def identity_segments
      [ title, lead_text, *central_claim_texts, *relevant_gap_questions ].reject(&:blank?)
    end

    def subject_reference_text
      [ title, lead_text, *central_claim_texts ].reject(&:blank?).join(" ")
    end

    def mentions_any_subject?(subjects)
      return true if subjects.blank?

      subject_reference = subject_reference_text
      return false if subject_reference.blank?

      normalized_subject_reference = normalized_tokens_for(subject_reference)
      subjects.any? do |subject|
        normalized_tokens_for(subject).all? { |token| normalized_subject_reference.include?(token) }
      end
    end

    private

    def root_article
      @investigation.root_article
    end

    def claim_rank_for(record)
      [
        record.title_related? ? 0 : 1,
        ROLE_PRIORITY.fetch(record.role.to_s, 9),
        -record.importance_score.to_f
      ]
    end

    def central_claim?(record)
      return false unless record.claim&.canonical_text.present?
      return true if record.title_related? || record.role_headline? || record.role_lead?

      importance = record.importance_score.to_f
      return false if importance < 0.8

      claim_mentions_primary_subject?(record.claim.canonical_text)
    end

    def claim_mentions_primary_subject?(text)
      return false if primary_subject_tokens.empty?

      tokens = normalized_tokens_for(text)
      primary_subject_tokens.any? { |token| tokens.include?(token) }
    end

    def gap_relevant?(question)
      return true if primary_subject_tokens.empty?
      return true if claim_mentions_primary_subject?(question)

      (normalized_tokens_for(question) & reference_keywords).size >= 2
    end

    def reference_keywords
      @reference_keywords ||= normalized_tokens_for([ title, lead_text, *central_claim_texts ].join(" "))
    end

    def title_keywords
      @title_keywords ||= normalized_tokens_for(title)
    end

    def fallback_claim_texts
      @investigation.claim_assessments.includes(:claim)
        .sort_by { |assessment| fallback_claim_rank_for(assessment) }
        .filter_map { |assessment| assessment.claim&.canonical_text.to_s.squish.presence }
        .uniq
        .first(3)
    end

    def fallback_claim_rank_for(assessment)
      text = assessment.claim&.canonical_text.to_s
      [
        claim_mentions_primary_subject?(text) ? 0 : 1,
        assessment.verdict == "not_checkable" ? 1 : 0,
        text.length
      ]
    end

    def normalized_tokens_for(text)
      text.to_s.downcase.scan(/[[:alnum:]][[:alnum:]\-]+/)
        .reject { |token| token.length < 4 || GENERIC_ENTITY_TOKENS.include?(token) }
        .to_set
    end

    def lead_sentence?(sentence)
      return true if title.blank?

      tokens = normalized_tokens_for(sentence)
      return false if tokens.empty?
      return true if (tokens & title_keywords).size >= 2

      primary_subject_tokens.any? { |token| tokens.include?(token) }
    end
  end
end
