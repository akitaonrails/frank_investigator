module Parsing
  class ContentQualityGate
    Result = Struct.new(:pass, :reason, keyword_init: true)

    MINIMUM_BODY_LENGTH = 200

    LOGIN_TERMS = %w[
      login senha password entrar cadastre sign\ in sign\ up
      criar\ conta esqueci forgot iniciar\ sessão
    ].freeze

    CONSENT_TERMS = %w[
      cookie cookies consent lgpd gdpr privacidade privacy
      aceitar\ cookies accept\ cookies política\ de\ cookies
    ].freeze

    def self.call(body_text:, title: nil, url: nil)
      new(body_text:, title:, url:).call
    end

    def initialize(body_text:, title: nil, url: nil)
      @body_text = body_text.to_s.squish
      @title = title.to_s
      @url = url.to_s
    end

    def call
      return fail_result(:empty_shell) if @body_text.blank?
      return fail_result(:too_short) if @body_text.length < MINIMUM_BODY_LENGTH
      return fail_result(:login_page) if login_page?
      return fail_result(:consent_page) if consent_page?

      Result.new(pass: true, reason: nil)
    end

    private

    def fail_result(reason)
      Result.new(pass: false, reason:)
    end

    def login_page?
      sample = @body_text[0, 500].downcase
      matches = LOGIN_TERMS.count { |term| sample.include?(term) }
      matches >= 3
    end

    def consent_page?
      lower = @body_text.downcase
      matches = CONSENT_TERMS.count { |term| lower.include?(term) }
      # Consent page: dominated by consent language relative to total content
      matches >= 3 && @body_text.length < 1000
    end
  end
end
