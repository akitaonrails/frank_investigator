if defined?(RubyLLM)
  RubyLLM.configure do |config|
    config.openrouter_api_key = ENV["OPENROUTER_API_KEY"] if ENV["OPENROUTER_API_KEY"].present?
    config.openai_api_key = ENV["OPENAI_API_KEY"] if ENV["OPENAI_API_KEY"].present?
    # Keep direct-OpenAI chat on the Chat Completions wire. RubyLLM 2.0 defaults
    # OpenAI chat to the Responses API, which would change request/response shapes.
    config.openai_protocol = :chat_completions
  end
end
