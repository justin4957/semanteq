import Config

# Test-specific configuration
config :semanteq, :anthropic, api_key: "test-api-key"
config :semanteq, :openai, api_key: "test-openai-api-key"

config :semanteq, :http, port: 4002

config :logger, level: :warning
