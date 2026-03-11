module Sources
  class ConnectorRouter
    def self.call(url:, host:, title:, html:, source_kind:, authority_tier:, authority_score:)
      new(url:, host:, title:, html:, source_kind:, authority_tier:, authority_score:).call
    end

    def initialize(url:, host:, title:, html:, source_kind:, authority_tier:, authority_score:)
      @url = url
      @host = host.to_s.downcase
      @title = title
      @html = html
      @source_kind = source_kind.to_sym
      @authority_tier = authority_tier.to_sym
      @authority_score = authority_score.to_f
    end

    def call
      connector.extract
    end

    private

    def connector
      case connector_key
      when :brazil_legislative then Connectors::BrazilLegislativeConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :brazil_court then Connectors::BrazilCourtConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :brazil_market_filing then Connectors::BrazilMarketFilingConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :us_government then Connectors::UsGovernmentConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :us_court then Connectors::UsCourtConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :us_sec_filing then Connectors::UsSecFilingConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :us_statistics then Connectors::UsStatisticsConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :government_record then Connectors::GovernmentRecordConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :scientific_paper then Connectors::ScientificPaperConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :company_filing then Connectors::CompanyFilingConnector.new(url: @url, host: @host, title: @title, html: @html)
      when :press_release then Connectors::PressReleaseConnector.new(url: @url, host: @host, title: @title, html: @html)
      else
        Connectors::NewsArticleConnector.new(
          url: @url,
          host: @host,
          title: @title,
          html: @html,
          source_kind: @source_kind,
          authority_tier: @authority_tier,
          authority_score: @authority_score
        )
      end
    end

    def connector_key
      # Brazil-specific routing
      return :brazil_legislative if @source_kind == :legislative_record && brazil_legislative_host?
      return :brazil_court if @source_kind == :court_record && brazil_court_host?
      return :brazil_market_filing if brazil_market_filing?

      # U.S.-specific routing
      return :us_sec_filing if us_sec_host?
      return :us_court if us_court_host?
      return :us_statistics if us_statistics_host?
      return :us_government if us_government_host?

      @source_kind
    end

    def brazil_legislative_host?
      @host.match?(/\b(camara|senado)\.leg\.br\z/i)
    end

    def brazil_court_host?
      @host.match?(/\bjus\.br\z/i)
    end

    def brazil_market_filing?
      @source_kind == :company_filing && (@host.match?(/\b(cvm\.gov\.br|b3\.com\.br)\z/i) || @url.match?(/fato-relevante|formulario-de-referencia|comunicado-ao-mercado|central-de-resultados/i))
    end

    def us_sec_host?
      @host.match?(/\bsec\.gov\z/i)
    end

    def us_court_host?
      @host.match?(/\b(uscourts\.gov|pacer\.gov|courtlistener\.com)\z/i)
    end

    def us_statistics_host?
      @host.match?(/\b(bls\.gov|census\.gov|federalreserve\.gov|stlouisfed\.org)\z/i)
    end

    def us_government_host?
      @host.match?(/\b(govinfo\.gov|congress\.gov|federalregister\.gov|whitehouse\.gov|gao\.gov|cbo\.gov)\z/i)
    end
  end
end
