import Config

# Anthropic API configuration
config :semanteq, :anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-3-haiku-20240307",
  base_url: "https://api.anthropic.com/v1",
  max_tokens: 4096,
  temperature: 0.7

# G-Lisp CLI configuration
config :semanteq, :glisp,
  project_dir: "/Users/coolbeans/Development/dev/glisp-stuff/glisp",
  clojure_alias: "test",
  timeout_ms: 30_000

# HTTP server configuration
config :semanteq, :http, port: 4001

# Import environment-specific config
import_config "#{config_env()}.exs"
