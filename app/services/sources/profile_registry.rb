require "yaml"

module Sources
  class ProfileRegistry
    Profile = Struct.new(
      :key,
      :name,
      :homepage_url,
      :host_patterns,
      :source_kind,
      :source_role,
      :authority_tier,
      :authority_score,
      :independence_group,
      :audience_country,
      :notes,
      keyword_init: true
    )

    class << self
      def all(region: nil)
        profiles = load_profiles
        return profiles unless region

        profiles.fetch(region.to_s, [])
      end

      def match(host)
        normalized_host = host.to_s.downcase

        load_profiles.values.flatten.find do |profile|
          profile.host_patterns.any? { |pattern| host_matches?(normalized_host, pattern) }
        end
      end

      private

      def load_profiles
        @profiles_mutex ||= Mutex.new
        return @load_profiles if defined?(@load_profiles) && @load_profiles

        @profiles_mutex.synchronize do
          @load_profiles ||= begin
            raw = YAML.load_file(Rails.root.join("config/source_profiles.yml"))
            raw.each_with_object({}) do |(region, profiles), acc|
              acc[region] = profiles.map do |key, attributes|
                Profile.new(
                  key:,
                  name: attributes.fetch("name"),
                  homepage_url: attributes.fetch("homepage_url"),
                  host_patterns: Array(attributes.fetch("host_patterns")),
                  source_kind: attributes.fetch("source_kind"),
                  source_role: attributes["source_role"],
                  authority_tier: attributes.fetch("authority_tier"),
                  authority_score: attributes.fetch("authority_score").to_f,
                  independence_group: attributes["independence_group"],
                  audience_country: attributes["audience_country"],
                  notes: attributes["notes"]
                )
              end
            end.freeze
          end
        end
      end

      def host_matches?(host, pattern)
        host == pattern || host.end_with?(".#{pattern}")
      end
    end
  end
end
