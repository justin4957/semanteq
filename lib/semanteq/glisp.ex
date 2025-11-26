defmodule Semanteq.Glisp do
  @moduledoc """
  CLI wrapper for interacting with G-Lisp via Clojure.

  Provides functions to evaluate G-expressions, test semantic equivalence,
  and generate test cases by calling the G-Lisp Clojure CLI directly.
  """

  require Logger

  @doc """
  Returns the G-Lisp project directory from configuration.
  """
  def project_dir do
    Application.get_env(:semanteq, :glisp)[:project_dir]
  end

  @doc """
  Returns the Clojure alias to use from configuration.
  """
  def clojure_alias do
    Application.get_env(:semanteq, :glisp)[:clojure_alias] || "test"
  end

  @doc """
  Returns the timeout in milliseconds from configuration.
  """
  def timeout_ms do
    Application.get_env(:semanteq, :glisp)[:timeout_ms] || 30_000
  end

  @doc """
  Evaluates a G-expression and returns the result.

  ## Parameters
    - gexpr: A G-expression map or JSON string

  ## Returns
    - `{:ok, result}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> Semanteq.Glisp.eval(%{"g" => "lit", "v" => 42})
      {:ok, 42}
  """
  def eval(gexpr) do
    gexpr_json = encode_gexpr(gexpr)

    code = """
    (require '[glisp.output :as output])
    (require '[glisp.builtins :as builtins])
    (let [env (builtins/create-global-env)
          gexpr (clojure.data.json/read-str #{inspect(gexpr_json)} :key-fn keyword)]
      (output/eval-and-format gexpr env :format :json))
    """

    run_clojure(code)
  end

  @doc """
  Tests semantic equivalence between two G-expressions.

  ## Parameters
    - expr_a: First G-expression
    - expr_b: Second G-expression
    - opts: Options map with optional :inputs for test cases

  ## Returns
    - `{:ok, %{equivalent: boolean, details: map}}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> Semanteq.Glisp.test_equivalence(expr_a, expr_b, %{inputs: [[1, 2], [3, 4]]})
      {:ok, %{equivalent: true, details: %{}}}
  """
  def test_equivalence(expr_a, expr_b, opts \\ %{}) do
    expr_a_json = encode_gexpr(expr_a)
    expr_b_json = encode_gexpr(expr_b)
    inputs_json = Jason.encode!(opts[:inputs] || [])

    code = """
    (require '[glisp.equivalence :as equiv])
    (require '[glisp.builtins :as builtins])
    (require '[clojure.data.json :as json])
    (let [env (builtins/create-global-env)
          expr-a (json/read-str #{inspect(expr_a_json)} :key-fn keyword)
          expr-b (json/read-str #{inspect(expr_b_json)} :key-fn keyword)
          inputs (json/read-str #{inspect(inputs_json)})
          result (equiv/semantically-equivalent? expr-a expr-b
                   :env env
                   :test-inputs inputs)]
      (json/write-str {:equivalent result}))
    """

    case run_clojure(code) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, result} -> {:ok, %{equivalent: result}}
      error -> error
    end
  end

  @doc """
  Generates test cases for a given schema.

  ## Parameters
    - schema: A schema map describing the function signature
    - opts: Options map with optional :strategy (:boundary, :random, :combinatorial)

  ## Returns
    - `{:ok, [test_case]}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> Semanteq.Glisp.generate_tests(%{input_types: [:number, :number]}, %{strategy: :boundary})
      {:ok, [%{inputs: [0, 0]}, %{inputs: [1, -1]}, ...]}
  """
  def generate_tests(schema, opts \\ %{}) do
    schema_json = Jason.encode!(schema)
    strategy = opts[:strategy] || :boundary

    code = """
    (require '[glisp.test-generator :as gen])
    (require '[clojure.data.json :as json])
    (let [schema (json/read-str #{inspect(schema_json)} :key-fn keyword)
          test-cases (gen/generate-test-cases schema :strategy #{inspect(strategy)})]
      (json/write-str (gen/test-cases->json test-cases)))
    """

    run_clojure(code)
  end

  @doc """
  Evaluates with trace capture for debugging.

  ## Parameters
    - gexpr: A G-expression to evaluate
    - opts: Options map with optional :level (:minimal, :standard, :verbose)

  ## Returns
    - `{:ok, %{result: any, trace: map}}` on success
    - `{:error, reason}` on failure
  """
  def eval_with_trace(gexpr, opts \\ %{}) do
    gexpr_json = encode_gexpr(gexpr)
    level = opts[:level] || :standard

    code = """
    (require '[glisp.trace :as trace])
    (require '[glisp.builtins :as builtins])
    (require '[clojure.data.json :as json])
    (let [env (builtins/create-global-env)
          gexpr (json/read-str #{inspect(gexpr_json)} :key-fn keyword)
          {:keys [result trace]} (trace/eval-with-trace gexpr env :level #{inspect(level)})]
      (json/write-str {:result result :trace (trace/trace->json trace)}))
    """

    run_clojure(code)
  end

  @doc """
  Checks if G-Lisp CLI is available and working.

  ## Returns
    - `{:ok, version_info}` if G-Lisp is accessible
    - `{:error, reason}` if not
  """
  def health_check do
    code = """
    (require '[clojure.data.json :as json])
    (json/write-str {:status "ok" :glisp_available true})
    """

    run_clojure(code)
  end

  # Private functions

  defp encode_gexpr(gexpr) when is_binary(gexpr), do: gexpr
  defp encode_gexpr(gexpr) when is_map(gexpr), do: Jason.encode!(gexpr)

  defp run_clojure(code) do
    dir = project_dir()
    alias_name = clojure_alias()
    _timeout = timeout_ms()

    args = ["-M:#{alias_name}", "-e", code]

    Logger.debug("Running Clojure: clojure #{Enum.join(args, " ")}")

    # Note: System.cmd doesn't support timeout directly.
    # For timeout support, consider using Task.async/await or Port
    case System.cmd("clojure", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        parse_clojure_output(output)

      {output, exit_code} ->
        Logger.error("Clojure command failed with exit code #{exit_code}: #{output}")
        {:error, %{exit_code: exit_code, output: output}}
    end
  rescue
    error ->
      Logger.error("Failed to run Clojure: #{inspect(error)}")
      {:error, %{exception: inspect(error)}}
  end

  defp parse_clojure_output(output) do
    output = String.trim(output)

    case Jason.decode(output) do
      {:ok, result} ->
        {:ok, result}

      {:error, _} ->
        # Try to extract JSON from output (there may be logging before it)
        case extract_json(output) do
          {:ok, result} -> {:ok, result}
          :error -> {:ok, output}
        end
    end
  end

  defp extract_json(output) do
    # Look for JSON object or array at end of output
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "{") or String.starts_with?(line, "[") do
        case Jason.decode(line) do
          {:ok, result} -> {:ok, result}
          _ -> nil
        end
      end
    end)
  end
end
