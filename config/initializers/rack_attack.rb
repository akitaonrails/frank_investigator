Rack::Attack.throttle("submissions/ip/minute", limit: 5, period: 60.seconds) do |req|
  req.ip if req.path == "/" && req.get? && req.params["url"].present?
end

Rack::Attack.throttle("submissions/ip/hour", limit: 30, period: 1.hour) do |req|
  req.ip if req.path == "/" && req.get? && req.params["url"].present?
end

Rack::Attack.throttle("requests/ip", limit: 120, period: 60.seconds) do |req|
  req.ip
end

Rack::Attack.blocklist("bad-hosts") do |req|
  url = req.params["url"].to_s
  next false if url.blank?

  begin
    uri = URI.parse(url.match?(/\Ahttps?:\/\//i) ? url : "https://#{url}")
    !Security::SsrfValidator.safe?(uri.to_s)
  rescue URI::InvalidURIError
    true
  end
end

Rack::Attack.throttled_responder = lambda do |req|
  [429, { "Content-Type" => "text/plain" }, ["Rate limit exceeded. Try again later.\n"]]
end

Rack::Attack.blocklisted_responder = lambda do |req|
  [403, { "Content-Type" => "text/plain" }, ["This URL is not allowed.\n"]]
end
