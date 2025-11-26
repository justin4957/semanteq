defmodule Semanteq.Generator do
  @moduledoc """
  Core orchestration module for G-Lisp code generation and testing.

  Combines LLM-based code generation with G-Lisp evaluation and testing
  to produce validated G-expressions from natural language prompts.
  """

  require Logger

  alias Semanteq.{Anthropic, Glisp}

  @doc """
  Generates and tests a G-expression from a natural language prompt.

  This is the main entry point for the generation pipeline. It:
  1. Generates a G-expression using Claude
  2. Evaluates the expression in G-Lisp
  3. Optionally runs tests against a schema

  ## Parameters
    - prompt: Natural language description of the desired code
    - opts: Options map with:
      - `:schema` - Schema for test generation
      - `:test_inputs` - Specific inputs to test
      - `:with_trace` - Include evaluation trace (boolean)

  ## Returns
    - `{:ok, result}` with generation results
    - `{:error, reason}` on failure

  ## Examples

      iex> Semanteq.Generator.generate_and_test("Create a function that doubles a number")
      {:ok, %{
        prompt: "Create a function that doubles a number",
        gexpr: %{"g" => "lam", ...},
        evaluation: %{result: ...},
        tests: %{passed: 5, failed: 0}
      }}
  """
  def generate_and_test(prompt, opts \\ %{}) do
    Logger.info("Starting generation pipeline for prompt: #{String.slice(prompt, 0, 50)}...")

    with {:ok, gexpr} <- generate_gexpr(prompt, opts),
         {:ok, eval_result} <- evaluate_gexpr(gexpr, opts),
         {:ok, test_result} <- run_tests(gexpr, opts) do
      result = %{
        prompt: prompt,
        gexpr: gexpr,
        evaluation: eval_result,
        tests: test_result
      }

      Logger.info("Generation pipeline completed successfully")
      {:ok, result}
    else
      {:error, step, reason} ->
        Logger.error("Generation pipeline failed at #{step}: #{inspect(reason)}")
        {:error, %{step: step, reason: reason}}

      {:error, reason} ->
        Logger.error("Generation pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generates a G-expression from a prompt using the LLM.

  ## Parameters
    - prompt: Natural language description
    - opts: Options passed to Anthropic client

  ## Returns
    - `{:ok, gexpr}` on success
    - `{:error, :generate, reason}` on failure
  """
  def generate_gexpr(prompt, opts \\ %{}) do
    case Anthropic.generate_gexpr(prompt, Map.to_list(opts)) do
      {:ok, gexpr} ->
        Logger.debug("Generated G-expression: #{inspect(gexpr)}")
        {:ok, gexpr}

      {:error, reason} ->
        {:error, :generate, reason}
    end
  end

  @doc """
  Evaluates a G-expression in G-Lisp.

  ## Parameters
    - gexpr: The G-expression to evaluate
    - opts: Options with optional `:with_trace` flag

  ## Returns
    - `{:ok, result}` on success
    - `{:error, :evaluate, reason}` on failure
  """
  def evaluate_gexpr(gexpr, opts \\ %{}) do
    eval_fn =
      if Map.get(opts, :with_trace, false) do
        &Glisp.eval_with_trace/2
      else
        fn expr, _opts -> Glisp.eval(expr) end
      end

    case eval_fn.(gexpr, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, :evaluate, reason}
    end
  end

  @doc """
  Runs tests against a G-expression.

  ## Parameters
    - gexpr: The G-expression to test
    - opts: Options with `:schema` or `:test_inputs`

  ## Returns
    - `{:ok, test_results}` on success
    - `{:error, :test, reason}` on failure
  """
  def run_tests(gexpr, opts \\ %{}) do
    cond do
      Map.has_key?(opts, :schema) ->
        run_schema_tests(gexpr, opts.schema, opts)

      Map.has_key?(opts, :test_inputs) ->
        run_input_tests(gexpr, opts.test_inputs)

      true ->
        # No tests requested
        {:ok, %{skipped: true, reason: "No schema or test_inputs provided"}}
    end
  end

  @doc """
  Tests equivalence between two G-expressions.

  ## Parameters
    - expr_a: First G-expression
    - expr_b: Second G-expression
    - opts: Options with optional `:inputs` for test cases

  ## Returns
    - `{:ok, %{equivalent: boolean, details: map}}` on success
    - `{:error, reason}` on failure
  """
  def test_equivalence(expr_a, expr_b, opts \\ %{}) do
    Glisp.test_equivalence(expr_a, expr_b, opts)
  end

  @doc """
  Generates and refines a G-expression with feedback loop.

  Attempts to generate a valid G-expression, and if evaluation fails,
  refines the expression up to `max_retries` times.

  ## Parameters
    - prompt: Natural language description
    - opts: Options with optional `:max_retries` (default 3)

  ## Returns
    - `{:ok, result}` with final successful result
    - `{:error, reason}` if all retries exhausted
  """
  def generate_with_refinement(prompt, opts \\ %{}) do
    max_retries = Map.get(opts, :max_retries, 3)
    do_generate_with_refinement(prompt, opts, max_retries, [])
  end

  # Private functions

  defp run_schema_tests(gexpr, schema, opts) do
    case Glisp.generate_tests(schema, opts) do
      {:ok, test_cases} ->
        results = run_test_cases(gexpr, test_cases)
        {:ok, summarize_test_results(results)}

      {:error, reason} ->
        {:error, :test, reason}
    end
  end

  defp run_input_tests(gexpr, inputs) do
    results =
      Enum.map(inputs, fn input ->
        # Wrap the gexpr in an application with the input
        app_expr = wrap_in_application(gexpr, input)

        case Glisp.eval(app_expr) do
          {:ok, result} ->
            %{input: input, result: result, status: :passed}

          {:error, reason} ->
            %{input: input, error: reason, status: :failed}
        end
      end)

    {:ok, summarize_test_results(results)}
  end

  defp run_test_cases(gexpr, test_cases) when is_list(test_cases) do
    Enum.map(test_cases, fn test_case ->
      inputs = Map.get(test_case, "inputs", Map.get(test_case, :inputs, []))
      expected = Map.get(test_case, "expected", Map.get(test_case, :expected))

      app_expr = wrap_in_application(gexpr, inputs)

      case Glisp.eval(app_expr) do
        {:ok, result} ->
          if expected do
            if result == expected do
              %{inputs: inputs, expected: expected, actual: result, status: :passed}
            else
              %{inputs: inputs, expected: expected, actual: result, status: :failed}
            end
          else
            %{inputs: inputs, actual: result, status: :passed}
          end

        {:error, reason} ->
          %{inputs: inputs, error: reason, status: :error}
      end
    end)
  end

  defp run_test_cases(_gexpr, _test_cases), do: []

  defp wrap_in_application(gexpr, inputs) when is_list(inputs) do
    args = Enum.map(inputs, fn input -> %{"g" => "lit", "v" => input} end)

    %{
      "g" => "app",
      "v" => %{
        "fn" => gexpr,
        "args" => args
      }
    }
  end

  defp wrap_in_application(gexpr, input) do
    wrap_in_application(gexpr, [input])
  end

  defp summarize_test_results(results) do
    passed = Enum.count(results, &(&1.status == :passed))
    failed = Enum.count(results, &(&1.status == :failed))
    errors = Enum.count(results, &(&1.status == :error))

    %{
      total: length(results),
      passed: passed,
      failed: failed,
      errors: errors,
      results: results
    }
  end

  defp do_generate_with_refinement(_prompt, _opts, 0, attempts) do
    {:error, %{reason: :max_retries_exceeded, attempts: Enum.reverse(attempts)}}
  end

  defp do_generate_with_refinement(prompt, opts, retries_left, attempts) do
    case generate_and_test(prompt, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{step: step, reason: reason}} = error ->
        attempt = %{
          retry: length(attempts) + 1,
          step: step,
          error: reason
        }

        # Try to refine based on the error
        feedback = build_feedback(step, reason)

        case Anthropic.generate_gexpr("#{prompt}\n\nPrevious attempt failed: #{feedback}") do
          {:ok, refined_gexpr} ->
            # Store this attempt
            new_attempts = [Map.put(attempt, :refined_gexpr, refined_gexpr) | attempts]

            # Try again with the refined expression
            refined_opts = Map.put(opts, :gexpr_override, refined_gexpr)
            do_generate_with_refinement(prompt, refined_opts, retries_left - 1, new_attempts)

          {:error, _} ->
            # Refinement failed, return original error
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp build_feedback(:generate, reason) do
    "Failed to generate valid G-expression: #{inspect(reason)}"
  end

  defp build_feedback(:evaluate, reason) do
    "G-expression evaluation failed: #{inspect(reason)}"
  end

  defp build_feedback(:test, reason) do
    "Tests failed: #{inspect(reason)}"
  end

  defp build_feedback(_step, reason) do
    "Error: #{inspect(reason)}"
  end
end
