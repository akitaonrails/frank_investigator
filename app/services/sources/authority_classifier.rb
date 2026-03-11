module Sources
  class AuthorityClassifier
    Result = Struct.new(:source_kind, :authority_tier, :authority_score, :independence_group, keyword_init: true)

    GOVERNMENT_HOST_PATTERNS = [/.gov\z/, /\bparliament\./i, /\bsenate\./i, /\bcourt/i].freeze
    SCIENCE_HOST_PATTERNS = [/\bpubmed\b/i, /\barxiv\b/i, /\bnature\.com\z/i, /\bscience\.org\z/i, /\bdoi\.org\z/i].freeze
    COMPANY_FILING_HOST_PATTERNS = [/\bsec\.gov\z/i, /\binvestor\./i].freeze
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
      return Result.new(source_kind: :government_record, authority_tier: :primary, authority_score: 0.98, independence_group:) if matches?(GOVERNMENT_HOST_PATTERNS)
      return Result.new(source_kind: :scientific_paper, authority_tier: :primary, authority_score: 0.93, independence_group:) if matches?(SCIENCE_HOST_PATTERNS) || @title.include?("study")
      return Result.new(source_kind: :company_filing, authority_tier: :primary, authority_score: 0.91, independence_group:) if matches?(COMPANY_FILING_HOST_PATTERNS)
      return Result.new(source_kind: :press_release, authority_tier: :primary, authority_score: 0.76, independence_group:) if matches?(PRESS_RELEASE_HOST_PATTERNS) || press_release_url?
      return Result.new(source_kind: :social_post, authority_tier: :low, authority_score: 0.22, independence_group:) if matches?(SOCIAL_HOST_PATTERNS)
      return Result.new(source_kind: :reference, authority_tier: :secondary, authority_score: 0.42, independence_group:) if matches?(REFERENCE_HOST_PATTERNS)

      Result.new(source_kind: :news_article, authority_tier: :secondary, authority_score: 0.58, independence_group:)
    end

    private

    def matches?(patterns)
      patterns.any? { |pattern| @host.match?(pattern) }
    end

    def press_release_url?
      @url.include?("/press-release") || @url.include?("/press/") || @title.include?("press release")
    end

    def independence_group
      @independence_group ||= begin
        labels = @host.split(".")
        labels.last(2).join(".").presence || @host
      end
    end
  end
end
