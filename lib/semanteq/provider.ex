defmodule Semanteq.Provider do
  @moduledoc """
  Behaviour definition for LLM providers.

  This module defines the common interface that all LLM providers must implement.
  It enables runtime provider switching and supports multiple providers simultaneously.

  ## Implementing a Provider

  To implement a new provider, create a module that implements all callbacks:

      defmodule MyProvider do
        @behaviour Semanteq.Provider

        @impl true
        def generate_gexpr(prompt, opts), do: ...

        @impl true
        def validate_gexpr(gexpr, context), do: ...

        @impl true
        def refine_gexpr(gexpr, feedback, opts), do: ...

        @impl true
        def health_check(), do: ...

        @impl true
        def name(), do: :my_provider

        @impl true
        def config(), do: ...
      end

  ## Using Providers

  The active provider can be configured in config.exs:

      config :semanteq, :provider, active: :anthropic

  Or switched at runtime:

      Semanteq.Provider.set_active(:openai)
      Semanteq.Provider.get_active()

  ## Available Providers

  - `:anthropic` - Anthropic Claude API (default)
  - `:mock` - Mock provider for testing
  """

  @doc """
  Generates a G-expression from a natural language prompt.

  ## Parameters
    - prompt: Natural language description of the desired code
    - opts: Provider-specific options (keyword list)

  ## Returns
    - `{:ok, gexpr}` on success (parsed JSON map)
    - `{:error, reason}` on failure
  """
  @callback generate_gexpr(prompt :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Validates a G-expression and provides feedback.

  ## Parameters
    - gexpr: A G-expression to validate
    - context: Optional context about what the expression should do

  ## Returns
    - `{:ok, %{valid: boolean, issues: list, suggestions: list}}` with validation results
    - `{:error, reason}` on failure
  """
  @callback validate_gexpr(gexpr :: map(), context :: String.t()) ::
              {:ok, %{valid: boolean(), issues: list(), suggestions: list()}}
              | {:error, term()}

  @doc """
  Refines a G-expression based on feedback or test failures.

  ## Parameters
    - gexpr: The original G-expression
    - feedback: Description of the issue or desired improvement
    - opts: Provider-specific options (keyword list)

  ## Returns
    - `{:ok, refined_gexpr}` on success
    - `{:error, reason}` on failure
  """
  @callback refine_gexpr(gexpr :: map(), feedback :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Checks if the provider is accessible and configured properly.

  ## Returns
    - `{:ok, info_map}` if provider is accessible
    - `{:error, reason}` if not
  """
  @callback health_check() :: {:ok, map()} | {:error, term()}

  @doc """
  Returns the provider's unique identifier.

  ## Returns
    - An atom identifying this provider (e.g., :anthropic, :openai)
  """
  @callback name() :: atom()

  @doc """
  Returns the provider's configuration.

  ## Returns
    - A map or keyword list of provider configuration
  """
  @callback config() :: map() | keyword()

  # ============================================================================
  # Provider Registry and Selection
  # ============================================================================

  @doc """
  Returns the list of registered providers.
  """
  def registered_providers do
    %{
      anthropic: Semanteq.Providers.Anthropic,
      mock: Semanteq.Providers.Mock
    }
  end

  @doc """
  Gets the currently active provider module.

  ## Returns
    - The module implementing the active provider

  ## Examples

      iex> Semanteq.Provider.get_active()
      Semanteq.Providers.Anthropic
  """
  def get_active do
    active_name = get_active_name()

    case Map.get(registered_providers(), active_name) do
      nil ->
        raise ArgumentError,
              "Unknown provider: #{active_name}. Available: #{inspect(Map.keys(registered_providers()))}"

      module ->
        module
    end
  end

  @doc """
  Gets the name of the currently active provider.

  ## Returns
    - Atom identifying the active provider
  """
  def get_active_name do
    case Process.get(:semanteq_provider) do
      nil ->
        config = Application.get_env(:semanteq, :provider, [])
        Keyword.get(config, :active, :anthropic)

      provider ->
        provider
    end
  end

  @doc """
  Sets the active provider for the current process.

  This allows runtime provider switching on a per-process basis.

  ## Parameters
    - provider_name: Atom identifying the provider

  ## Returns
    - :ok on success
    - {:error, reason} if provider doesn't exist

  ## Examples

      iex> Semanteq.Provider.set_active(:mock)
      :ok

      iex> Semanteq.Provider.set_active(:unknown)
      {:error, :unknown_provider}
  """
  def set_active(provider_name) when is_atom(provider_name) do
    if Map.has_key?(registered_providers(), provider_name) do
      Process.put(:semanteq_provider, provider_name)
      :ok
    else
      {:error, :unknown_provider}
    end
  end

  @doc """
  Resets the active provider to the default (from config).
  """
  def reset_active do
    Process.delete(:semanteq_provider)
    :ok
  end

  @doc """
  Executes a function with a specific provider temporarily active.

  ## Parameters
    - provider_name: The provider to use
    - fun: Zero-arity function to execute

  ## Returns
    - The result of the function

  ## Examples

      iex> Semanteq.Provider.with_provider(:mock, fn ->
      ...>   Semanteq.Provider.generate_gexpr("test")
      ...> end)
  """
  def with_provider(provider_name, fun) when is_atom(provider_name) and is_function(fun, 0) do
    previous = Process.get(:semanteq_provider)

    try do
      set_active(provider_name)
      fun.()
    after
      if previous do
        Process.put(:semanteq_provider, previous)
      else
        Process.delete(:semanteq_provider)
      end
    end
  end

  # ============================================================================
  # Delegated Functions (use active provider)
  # ============================================================================

  @doc """
  Generates a G-expression using the active provider.

  See `c:generate_gexpr/2` for details.
  """
  def generate_gexpr(prompt, opts \\ []) do
    get_active().generate_gexpr(prompt, opts)
  end

  @doc """
  Validates a G-expression using the active provider.

  See `c:validate_gexpr/2` for details.
  """
  def validate_gexpr(gexpr, context \\ "") do
    get_active().validate_gexpr(gexpr, context)
  end

  @doc """
  Refines a G-expression using the active provider.

  See `c:refine_gexpr/3` for details.
  """
  def refine_gexpr(gexpr, feedback, opts \\ []) do
    get_active().refine_gexpr(gexpr, feedback, opts)
  end

  @doc """
  Checks the health of the active provider.

  See `c:health_check/0` for details.
  """
  def health_check do
    get_active().health_check()
  end

  @doc """
  Returns the name of the active provider.
  """
  def name do
    get_active().name()
  end

  @doc """
  Returns the configuration of the active provider.
  """
  def provider_config do
    get_active().config()
  end

  @doc """
  Returns information about all registered providers.

  ## Returns
    - Map of provider names to their info
  """
  def list_providers do
    registered_providers()
    |> Enum.map(fn {name, module} ->
      {name,
       %{
         module: module,
         active: name == get_active_name()
       }}
    end)
    |> Map.new()
  end
end
