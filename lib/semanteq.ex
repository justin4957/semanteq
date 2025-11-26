defmodule Semanteq do
  @moduledoc """
  Semanteq - LLM-based testing service for G-Lisp DSL creation.

  Semanteq combines Claude AI with G-Lisp to enable:
  - Natural language to G-expression code generation
  - Automated testing of generated expressions
  - Semantic equivalence checking between expressions
  - Iterative refinement based on test feedback

  ## Quick Start

      # Generate and test a G-expression
      {:ok, result} = Semanteq.generate("Create a function that doubles a number")

      # Evaluate a G-expression directly
      {:ok, 42} = Semanteq.eval(%{"g" => "lit", "v" => 42})

      # Check if two expressions are equivalent
      {:ok, %{equivalent: true}} = Semanteq.equivalent?(expr_a, expr_b)

  ## HTTP API

  Semanteq also provides an HTTP API on port 4001:

      POST /generate     - Generate G-expr from prompt
      POST /eval         - Evaluate G-expression
      POST /test         - Test G-expression
      POST /equivalence  - Check equivalence
      POST /validate     - LLM validation
      POST /refine       - LLM refinement
      GET  /health       - Health check

  ## Configuration

  Set the following in your config:

      config :semanteq, :anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-3-haiku-20240307"

      config :semanteq, :glisp,
        project_dir: "/path/to/glisp"

      config :semanteq, :http,
        port: 4001
  """

  alias Semanteq.{Generator, Glisp, Anthropic}

  @doc """
  Generates and tests a G-expression from a natural language prompt.

  ## Parameters
    - prompt: Natural language description of the desired code
    - opts: Options map (see `Semanteq.Generator.generate_and_test/2`)

  ## Examples

      iex> Semanteq.generate("Create a function that adds two numbers")
      {:ok, %{prompt: "...", gexpr: %{...}, evaluation: %{...}, tests: %{...}}}
  """
  defdelegate generate(prompt, opts \\ %{}), to: Generator, as: :generate_and_test

  @doc """
  Generates a G-expression with automatic retry and refinement on failure.

  ## Parameters
    - prompt: Natural language description
    - opts: Options map with optional `:max_retries` (default 3)

  ## Examples

      iex> Semanteq.generate_with_refinement("Create a recursive factorial function")
      {:ok, %{prompt: "...", gexpr: %{...}, ...}}
  """
  defdelegate generate_with_refinement(prompt, opts \\ %{}),
    to: Generator,
    as: :generate_with_refinement

  @doc """
  Evaluates a G-expression in G-Lisp.

  ## Parameters
    - gexpr: A G-expression map

  ## Examples

      iex> Semanteq.eval(%{"g" => "lit", "v" => 42})
      {:ok, 42}

      iex> Semanteq.eval(%{"g" => "app", "v" => %{"fn" => %{"g" => "ref", "v" => "+"}, "args" => [%{"g" => "lit", "v" => 1}, %{"g" => "lit", "v" => 2}]}})
      {:ok, 3}
  """
  defdelegate eval(gexpr), to: Glisp

  @doc """
  Evaluates a G-expression with execution trace capture.

  ## Parameters
    - gexpr: A G-expression map
    - opts: Options map with optional `:level` (:minimal, :standard, :verbose)

  ## Examples

      iex> Semanteq.eval_with_trace(%{"g" => "lit", "v" => 42})
      {:ok, %{"result" => 42, "trace" => %{...}}}
  """
  defdelegate eval_with_trace(gexpr, opts \\ %{}), to: Glisp

  @doc """
  Tests if two G-expressions are semantically equivalent.

  ## Parameters
    - expr_a: First G-expression
    - expr_b: Second G-expression
    - opts: Options map with optional `:inputs` for test cases

  ## Examples

      iex> expr_a = %{"g" => "lam", "v" => %{"params" => ["x"], "body" => ...}}
      iex> expr_b = %{"g" => "lam", "v" => %{"params" => ["y"], "body" => ...}}
      iex> Semanteq.equivalent?(expr_a, expr_b, %{inputs: [[1], [2], [3]]})
      {:ok, %{equivalent: true}}
  """
  def equivalent?(expr_a, expr_b, opts \\ %{}) do
    Glisp.test_equivalence(expr_a, expr_b, opts)
  end

  @doc """
  Validates a G-expression using the LLM.

  ## Parameters
    - gexpr: A G-expression to validate
    - context: Optional context about what the expression should do

  ## Examples

      iex> Semanteq.validate(%{"g" => "lam", "v" => ...}, "Should double a number")
      {:ok, %{valid: true, issues: [], suggestions: []}}
  """
  defdelegate validate(gexpr, context \\ ""), to: Anthropic, as: :validate_gexpr

  @doc """
  Refines a G-expression based on feedback.

  ## Parameters
    - gexpr: The original G-expression
    - feedback: Description of the issue or desired improvement

  ## Examples

      iex> Semanteq.refine(gexpr, "Handle negative numbers")
      {:ok, %{"g" => "lam", "v" => ...}}
  """
  defdelegate refine(gexpr, feedback), to: Anthropic, as: :refine_gexpr

  @doc """
  Generates test cases for a schema.

  ## Parameters
    - schema: A schema map describing the function signature
    - opts: Options map with optional `:strategy`

  ## Examples

      iex> Semanteq.generate_tests(%{input_types: [:number]}, %{strategy: :boundary})
      {:ok, [%{inputs: [0]}, %{inputs: [1]}, ...]}
  """
  defdelegate generate_tests(schema, opts \\ %{}), to: Glisp

  @doc """
  Returns the health status of all services.

  ## Examples

      iex> Semanteq.health()
      %{glisp: %{status: "ok"}, anthropic: %{status: "ok", model: "..."}}
  """
  def health do
    %{
      glisp: check_service(Glisp.health_check()),
      anthropic: check_service(Anthropic.health_check())
    }
  end

  defp check_service({:ok, info}) when is_map(info), do: Map.merge(%{status: "ok"}, info)
  defp check_service({:ok, _}), do: %{status: "ok"}
  defp check_service({:error, reason}), do: %{status: "error", error: inspect(reason)}
end
