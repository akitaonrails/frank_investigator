module Analyzers
  module TextAnalysis
    STOP_WORDS = Set.new(%w[
      the a an is was were are be been being have has had do does did will would shall should
      may might can could of in on at to for with by from as it its this that these those
      and or but not no nor so yet if then than said says say
      o a os as um uma uns umas de do da dos das em no na nos nas por para com
      e ou mas nao nem se que como mais
    ]).freeze

    def self.normalize(text)
      sanitized = unicode_normalize(text)
      sanitized.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    # NFKC normalization + confusable character replacement.
    # Defends against homoglyph attacks (Cyrillic 'а' looking like Latin 'a',
    # fullwidth digits '５' instead of '5', etc.)
    CONFUSABLES = {
      "\u0410" => "A", "\u0430" => "a", # Cyrillic А/а
      "\u0412" => "B", "\u0432" => "b", # Cyrillic В/в (looks like B)
      "\u0415" => "E", "\u0435" => "e", # Cyrillic Е/е
      "\u041A" => "K", "\u043A" => "k", # Cyrillic К/к
      "\u041C" => "M", "\u043C" => "m", # Cyrillic М/м
      "\u041D" => "H", "\u043D" => "h", # Cyrillic Н/н (looks like H)
      "\u041E" => "O", "\u043E" => "o", # Cyrillic О/о
      "\u0420" => "P", "\u0440" => "p", # Cyrillic Р/р (looks like P)
      "\u0421" => "C", "\u0441" => "c", # Cyrillic С/с
      "\u0422" => "T", "\u0442" => "t", # Cyrillic Т/т (some fonts)
      "\u0425" => "X", "\u0445" => "x", # Cyrillic Х/х
      "\u0443" => "y",                  # Cyrillic у (looks like y)
      "\u0456" => "i",                  # Ukrainian і
      "\u04BB" => "h",                  # Cyrillic һ
      "\u2010" => "-", "\u2011" => "-", "\u2012" => "-", "\u2013" => "-", "\u2014" => "-", # dashes
      "\u2018" => "'", "\u2019" => "'", "\u201C" => "\"", "\u201D" => "\"", # quotes
      "\u00A0" => " ",                  # non-breaking space
      "\u200B" => "",                   # zero-width space
      "\u200C" => "",                   # zero-width non-joiner
      "\u200D" => "",                   # zero-width joiner
      "\uFEFF" => ""                    # BOM
    }.freeze

    CONFUSABLES_REGEX = Regexp.union(CONFUSABLES.keys).freeze

    def self.unicode_normalize(text)
      # Step 1: NFKC normalization (handles fullwidth chars, ligatures, etc.)
      normalized = text.to_s.unicode_normalize(:nfkc)
      # Step 2: Replace known confusable characters
      normalized.gsub(CONFUSABLES_REGEX, CONFUSABLES)
    end

    def self.tokenize(text, min_length: 3, remove_stop_words: true)
      tokens = normalize(text).split(/\s+/)
      tokens = tokens.reject { |t| t.length < min_length }
      tokens = tokens.reject { |t| STOP_WORDS.include?(t) } if remove_stop_words
      tokens.to_set
    end

    def self.simple_tokens(text)
      text.to_s.downcase.scan(/[a-z0-9]+/)
    end

    def self.jaccard_similarity(set_a, set_b)
      intersection = (set_a & set_b).size
      union = (set_a | set_b).size
      return 0.0 if union.zero?

      intersection.to_f / union
    end
  end
end
