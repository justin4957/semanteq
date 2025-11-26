defmodule Semanteq.MixProject do
  use Mix.Project

  def project do
    [
      app: :semanteq,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Semanteq.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP client for Anthropic API
      {:req, "~> 0.4"},
      # JSON encoding/decoding
      {:jason, "~> 1.4"},
      # HTTP server
      {:plug_cowboy, "~> 2.6"}
    ]
  end
end
