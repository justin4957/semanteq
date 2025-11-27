defmodule Semanteq.Anthropic do
  @moduledoc """
  Legacy Anthropic Claude API client for G-Lisp code generation.

  **Note:** This module is maintained for backwards compatibility.
  New code should use `Semanteq.Provider` or `Semanteq.Providers.Anthropic` directly.

  ## Migration

  Instead of:

      Semanteq.Anthropic.generate_gexpr(prompt)

  Use:

      Semanteq.Provider.generate_gexpr(prompt)

  Or for explicit Anthropic usage:

      Semanteq.Providers.Anthropic.generate_gexpr(prompt)
  """

  @doc """
  Returns configuration from application environment.
  """
  defdelegate config(), to: Semanteq.Providers.Anthropic

  @doc """
  Generates a G-expression from a natural language prompt.

  See `Semanteq.Providers.Anthropic.generate_gexpr/2` for details.
  """
  defdelegate generate_gexpr(prompt, opts \\ []), to: Semanteq.Providers.Anthropic

  @doc """
  Validates a G-expression and provides feedback.

  See `Semanteq.Providers.Anthropic.validate_gexpr/2` for details.
  """
  defdelegate validate_gexpr(gexpr, context \\ ""), to: Semanteq.Providers.Anthropic

  @doc """
  Refines a G-expression based on feedback or test failures.

  See `Semanteq.Providers.Anthropic.refine_gexpr/3` for details.
  """
  defdelegate refine_gexpr(gexpr, feedback, opts \\ []), to: Semanteq.Providers.Anthropic

  @doc """
  Checks if the Anthropic API is accessible.

  See `Semanteq.Providers.Anthropic.health_check/0` for details.
  """
  defdelegate health_check(), to: Semanteq.Providers.Anthropic
end
