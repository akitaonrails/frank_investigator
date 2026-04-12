require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module FrankInvestigator
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    config.i18n.default_locale = ENV.fetch("FRANK_INVESTIGATOR_LOCALE", "pt-BR").to_sym
    config.i18n.available_locales = %i[en pt-BR]
    config.i18n.fallbacks = true

    config.x.frank_investigator = ActiveSupport::OrderedOptions.new
    config.x.frank_investigator.max_link_depth = ENV.fetch("FRANK_INVESTIGATOR_MAX_LINK_DEPTH", 1).to_i
    config.x.frank_investigator.article_freshness_ttl = ENV.fetch("FRANK_INVESTIGATOR_ARTICLE_FRESHNESS_TTL", 3600).to_i # seconds
    config.x.frank_investigator.fetcher_class = ENV.fetch("FRANK_INVESTIGATOR_FETCHER_CLASS", "Fetchers::ChromiumFetcher")
    config.x.frank_investigator.llm_client_class = ENV.fetch("FRANK_INVESTIGATOR_LLM_CLIENT_CLASS", "Llm::RubyLlmClient")
    config.x.frank_investigator.vector_search_enabled = ENV.fetch("FRANK_INVESTIGATOR_VECTOR_SEARCH_ENABLED", "true") == "true"
    config.x.frank_investigator.embedding_provider = ENV.fetch("FRANK_INVESTIGATOR_EMBEDDING_PROVIDER", "openrouter")
    config.x.frank_investigator.embedding_model = ENV.fetch(
      "FRANK_INVESTIGATOR_EMBEDDING_MODEL",
      "openai/text-embedding-3-small"
    )
    config.x.frank_investigator.embedding_dimensions = ENV.fetch("FRANK_INVESTIGATOR_EMBEDDING_DIMENSIONS", 1536).to_i
    config.x.frank_investigator.sqlite_vec_path = ENV.fetch(
      "FRANK_INVESTIGATOR_SQLITE_VEC_PATH",
      Rails.root.join("vendor/sqlite-vec/vec0.so").to_s
    )
    config.x.frank_investigator.openrouter_models = ENV.fetch(
      "FRANK_INVESTIGATOR_OPENROUTER_MODELS",
      "openai/gpt-5-mini,anthropic/claude-sonnet-4-6,google/gemini-2.5-pro"
    ).split(",").map(&:strip).reject(&:blank?)
    config.x.frank_investigator.quarantined_models = ENV.fetch(
      "QUARANTINED_MODELS", ""
    ).split(",").map(&:strip).reject(&:blank?)
  end
end
