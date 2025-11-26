import Config

# Development-specific configuration
config :semanteq, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
