defmodule Semanteq.Application do
  @moduledoc """
  OTP Application for Semanteq.

  Starts the HTTP server on the configured port (default 4001)
  and the session manager for tracking generation history.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    http_config = Application.get_env(:semanteq, :http, [])
    port = Keyword.get(http_config, :port, 4001)

    children = [
      # Session manager (ETS-based)
      Semanteq.Session,
      # HTTP server
      {Plug.Cowboy, scheme: :http, plug: Semanteq.Router, options: [port: port]}
    ]

    Logger.info("Starting Semanteq on port #{port}")

    opts = [strategy: :one_for_one, name: Semanteq.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
