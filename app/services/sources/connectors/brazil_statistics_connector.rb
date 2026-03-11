module Sources
  module Connectors
    class BrazilStatisticsConnector < BaseConnector
      # Statistical indicator patterns
      INDICATOR_REGEX = /\b(IPCA|INPC|IGP-M|IGP-DI|Selic|CDI|PIB|PNAD|Censo|POF|PMS|PMC|PIM|CAGED|IDH|IDHM|Gini)\b/i

      # Survey/study patterns
      SURVEY_REGEX = /\b(Pesquisa|Levantamento|Estimativa|Censo|Indicador|Indice|Índice)\b[^\n]{0,60}/i

      AGENCY_MAP = {
        "ibge.gov.br" => { name: "IBGE", domain: "statistics", score: 0.97 },
        "ipea.gov.br" => { name: "Ipea", domain: "economic_research", score: 0.93 },
        "ipeadata.gov.br" => { name: "Ipea Data", domain: "economic_research", score: 0.93 },
        "inep.gov.br" => { name: "Inep", domain: "education_statistics", score: 0.95 },
        "datasus.saude.gov.br" => { name: "DataSUS", domain: "health_statistics", score: 0.95 },
        "saude.gov.br/datasus" => { name: "DataSUS", domain: "health_statistics", score: 0.95 },
        "dados.gov.br" => { name: "Portal de Dados Abertos", domain: "open_data", score: 0.92 },
        "sidra.ibge.gov.br" => { name: "SIDRA/IBGE", domain: "statistics", score: 0.97 },
        "mapas.ibge.gov.br" => { name: "IBGE Mapas", domain: "geospatial_statistics", score: 0.96 }
      }.freeze

      def extract
        Result.new(
          published_at: generic_published_at,
          source_kind: :government_record,
          authority_tier: :primary,
          authority_score: agency_info[:score],
          metadata_json: {
            "connector" => "brazil_statistics",
            "site_name" => generic_site_name,
            "source_role" => "neutral_statistics",
            "agency" => agency_info[:name],
            "statistical_domain" => agency_info[:domain],
            "indicator" => indicator,
            "survey_reference" => survey_reference
          }.compact
        )
      end

      private

      def agency_info
        @agency_info ||= begin
          match = AGENCY_MAP.find { |pattern, _| @host.include?(pattern) || @url.include?(pattern) }
          match ? match[1] : { name: generic_site_name, domain: "statistics", score: 0.93 }
        end
      end

      def indicator
        extract_from_text(INDICATOR_REGEX)
      end

      def survey_reference
        extract_from_text(SURVEY_REGEX)
      end

    end
  end
end
