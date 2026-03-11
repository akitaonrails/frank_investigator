module Sources
  class AuthorityClassifier
    Result = Struct.new(:source_kind, :authority_tier, :authority_score, :independence_group, :source_role, keyword_init: true)

    # Brazil-specific patterns
    BRAZIL_LEGISLATIVE_HOST_PATTERNS = [/\bcamara\.leg\.br\z/i, /\bsenado\.leg\.br\z/i, /\bcongressoemfoco\.uol\.com\.br\z/i].freeze
    BRAZIL_COURT_HOST_PATTERNS = [/\bjus\.br\z/i, /\bstf\.jus\.br\z/i, /\bstj\.jus\.br\z/i, /\btse\.jus\.br\z/i, /\btrf\d?\.jus\.br\z/i, /\btj[a-z]{2}\.jus\.br\z/i].freeze
    BRAZIL_MARKET_FILING_HOST_PATTERNS = [/\bcvm\.gov\.br\z/i, /\bb3\.com\.br\z/i, /\bri\./i, /\binvestidores\./i, /\bresultados\./i].freeze

    # U.S. authority patterns — Tier A: authenticated primary
    US_GOVINFO_HOST_PATTERNS = [/\bgovinfo\.gov\z/i].freeze
    US_CONGRESS_HOST_PATTERNS = [/\bcongress\.gov\z/i].freeze
    US_FEDERAL_REGISTER_HOST_PATTERNS = [/\bfederalregister\.gov\z/i].freeze
    US_FED_HOST_PATTERNS = [/\bfederalreserve\.gov\z/i].freeze
    US_FRED_HOST_PATTERNS = [/\bfred\.stlouisfed\.org\z/i, /\bstlouisfed\.org\z/i].freeze
    US_BLS_HOST_PATTERNS = [/\bbls\.gov\z/i].freeze
    US_CENSUS_HOST_PATTERNS = [/\bcensus\.gov\z/i].freeze
    US_COURTS_HOST_PATTERNS = [/\buscourts\.gov\z/i, /\bpacer\.gov\z/i, /\bcourtlistener\.com\z/i].freeze
    US_SEC_HOST_PATTERNS = [/\bsec\.gov\z/i, /\bedgar\b/i].freeze

    # U.S. authority patterns — Tier B: primary but political
    US_WHITEHOUSE_HOST_PATTERNS = [/\bwhitehouse\.gov\z/i].freeze

    # U.S. authority patterns — Tier C: independent oversight
    US_GAO_HOST_PATTERNS = [/\bgao\.gov\z/i].freeze
    US_CBO_HOST_PATTERNS = [/\bcbo\.gov\z/i].freeze

    # U.S. authority patterns — Tier D: research discovery
    US_NBER_HOST_PATTERNS = [/\bnber\.org\z/i].freeze

    # Generic patterns
    GOVERNMENT_HOST_PATTERNS = [/\.gov\z/, /\.gov\.br\z/i, /\bparliament\./i, /\bsenate\./i, /\bcourt/i].freeze
    SCIENCE_HOST_PATTERNS = [/\bpubmed\b/i, /\barxiv\b/i, /\bnature\.com\z/i, /\bscience\.org\z/i, /\bdoi\.org\z/i].freeze
    COMPANY_FILING_HOST_PATTERNS = [/\binvestor\./i].freeze
    PRESS_RELEASE_HOST_PATTERNS = [/\bprnewswire\.com\z/i, /\bbusinesswire\.com\z/i].freeze
    SOCIAL_HOST_PATTERNS = [/\bx\.com\z/i, /\btwitter\.com\z/i, /\bfacebook\.com\z/i, /\binstagram\.com\z/i, /\btiktok\.com\z/i, /\byoutube\.com\z/i].freeze
    REFERENCE_HOST_PATTERNS = [/\bwikipedia\.org\z/i].freeze

    def self.call(url:, host:, title: nil)
      new(url:, host:, title:).call
    end

    def initialize(url:, host:, title:)
      @url = url.to_s
      @host = host.to_s.downcase
      @title = title.to_s.downcase
    end

    def call
      if (profile = Sources::ProfileRegistry.match(@host))
        return Result.new(
          source_kind: profile.source_kind.to_sym,
          authority_tier: profile.authority_tier.to_sym,
          authority_score: profile.authority_score,
          independence_group: profile.independence_group.presence || independence_group,
          source_role: profile.source_role.present? ? profile.source_role.to_sym : :news_reporting
        )
      end

      # Brazil-specific
      return Result.new(source_kind: :legislative_record, authority_tier: :primary, authority_score: 0.97, independence_group:, source_role: :authenticated_legal_text) if matches?(BRAZIL_LEGISLATIVE_HOST_PATTERNS)
      return Result.new(source_kind: :court_record, authority_tier: :primary, authority_score: 0.97, independence_group:, source_role: :authenticated_legal_text) if matches?(BRAZIL_COURT_HOST_PATTERNS)
      return Result.new(source_kind: :company_filing, authority_tier: :primary, authority_score: 0.92, independence_group:, source_role: :authenticated_legal_text) if brazil_market_filing?

      # U.S. Tier A: authenticated primary sources
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.99, independence_group: "govinfo.gov", source_role: :authenticated_legal_text) if matches?(US_GOVINFO_HOST_PATTERNS)
      return Result.new(source_kind: :legislative_record, authority_tier: :primary, authority_score: 0.98, independence_group: "congress.gov", source_role: :authenticated_legal_text) if matches?(US_CONGRESS_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.97, independence_group: "federalregister.gov", source_role: :authenticated_legal_text) if matches?(US_FEDERAL_REGISTER_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.97, independence_group: "federalreserve.gov", source_role: :neutral_statistics) if matches?(US_FED_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.96, independence_group: "stlouisfed.org", source_role: :neutral_statistics) if matches?(US_FRED_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.97, independence_group: "bls.gov", source_role: :neutral_statistics) if matches?(US_BLS_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.96, independence_group: "census.gov", source_role: :neutral_statistics) if matches?(US_CENSUS_HOST_PATTERNS)
      return Result.new(source_kind: :court_record, authority_tier: :primary, authority_score: 0.97, independence_group: "uscourts.gov", source_role: :authenticated_legal_text) if matches?(US_COURTS_HOST_PATTERNS)
      return Result.new(source_kind: :company_filing, authority_tier: :primary, authority_score: 0.98, independence_group: "sec.gov", source_role: :authenticated_legal_text) if matches?(US_SEC_HOST_PATTERNS)

      # U.S. Tier B: primary but political/role-limited — confidence capped
      return Result.new(source_kind: :government_record, authority_tier: :secondary, authority_score: 0.72, independence_group: "whitehouse.gov", source_role: :official_position) if matches?(US_WHITEHOUSE_HOST_PATTERNS)

      # U.S. Tier C: independent oversight
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.96, independence_group: "gao.gov", source_role: :oversight) if matches?(US_GAO_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.96, independence_group: "cbo.gov", source_role: :oversight) if matches?(US_CBO_HOST_PATTERNS)

      # U.S. Tier D: research discovery
      return Result.new(source_kind: :scientific_paper, authority_tier: :secondary, authority_score: 0.78, independence_group: "nber.org", source_role: :research_discovery) if matches?(US_NBER_HOST_PATTERNS)

      # Generic patterns (non-U.S., non-Brazil specifics)
      return Result.new(source_kind: :company_filing, authority_tier: :primary, authority_score: 0.91, independence_group:, source_role: :authenticated_legal_text) if matches?(COMPANY_FILING_HOST_PATTERNS)
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.98, independence_group:, source_role: :unknown) if matches?(GOVERNMENT_HOST_PATTERNS)
      return Result.new(source_kind: :scientific_paper, authority_tier: :primary, authority_score: 0.93, independence_group:, source_role: :research_discovery) if matches?(SCIENCE_HOST_PATTERNS) || @title.include?("study")
      return Result.new(source_kind: :press_release, authority_tier: :primary, authority_score: 0.76, independence_group:, source_role: :official_position) if matches?(PRESS_RELEASE_HOST_PATTERNS) || press_release_url?
      return Result.new(source_kind: :social_post, authority_tier: :low, authority_score: 0.22, independence_group:, source_role: :unknown) if matches?(SOCIAL_HOST_PATTERNS)
      return Result.new(source_kind: :reference, authority_tier: :secondary, authority_score: 0.42, independence_group:, source_role: :unknown) if matches?(REFERENCE_HOST_PATTERNS)

      Result.new(source_kind: :news_article, authority_tier: :secondary, authority_score: 0.58, independence_group:, source_role: :news_reporting)
    end

    private

    def matches?(patterns)
      patterns.any? { |pattern| @host.match?(pattern) }
    end

    def press_release_url?
      @url.include?("/press-release") || @url.include?("/press/") || @title.include?("press release")
    end

    def brazil_market_filing?
      matches?(BRAZIL_MARKET_FILING_HOST_PATTERNS) || @url.match?(/fato-relevante|formulario-de-referencia|central-de-resultados|comunicado-ao-mercado/i)
    end

    def independence_group
      @independence_group ||= begin
        labels = @host.split(".")
        labels.last(2).join(".").presence || @host
      end
    end
  end
end
