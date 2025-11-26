import Config

# Production-specific configuration
config :semanteq, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")

config :logger, level: :info
