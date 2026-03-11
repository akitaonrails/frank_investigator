module Fetchers
  class HostProfile
    PROFILES = {
      "g1.globo.com" => { budget: 25_000, wait_for: nil },
      "globo.com" => { budget: 20_000, wait_for: nil },
      "folha.uol.com.br" => { budget: 15_000, wait_for: nil },
      "infomoney.com.br" => { budget: 20_000, wait_for: nil },
      "uol.com.br" => { budget: 15_000, wait_for: nil },
      "estadao.com.br" => { budget: 15_000, wait_for: nil },
      "valor.globo.com" => { budget: 20_000, wait_for: nil },
      "reuters.com" => { budget: 15_000, wait_for: nil },
      "bloomberg.com" => { budget: 20_000, wait_for: nil }
    }.freeze

    DEFAULT = { budget: 8_000, wait_for: nil }.freeze

    def self.for(url)
      host = URI.parse(url).host.to_s.downcase
      PROFILES[host] || DEFAULT
    rescue URI::InvalidURIError
      DEFAULT
    end
  end
end
