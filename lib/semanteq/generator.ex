defmodule Semanteq.Generator do
  @moduledoc """
  Core orchestration module for G-Lisp code generation and testing.

  Combines LLM-based code generation with G-Lisp evaluation and testing
  to produce validated G-expressions from natural language prompts.

  ## Retry Configuration

  The generator supports automatic retry with feedback when generation fails:

  - `:max_retries` - Maximum number of retry attempts (default: 3)
  - `:retry_on` - List of failure types to retry on (default: [:generate, :evaluate, :test])
  - `:backoff_ms` - Base backoff time between retries in ms (default: 100)
  - `:exponential_backoff` - Whether to use exponential backoff (default: true)

  ## Example

      opts = %{
        max_retries: 5,
        retry_on: [:evaluate, :test],
        backoff_ms: 200
      }
      {:ok, result} = Semanteq.Generator.generate_with_retry("Create a factorial function", opts)
  """

  require Logger

  alias Semanteq.{Anthropic, Glisp}

  @default_max_retries 3
  @default_retry_on [:generate, :evaluate, :test]
  @default_backoff_ms 100
  @default_batch_parallelism 5

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
  Generates and tests a G-expression with automatic retry on failure.

  This function wraps `generate_and_test/2` with a configurable retry mechanism.
  When a failure occurs, it feeds the error back to the LLM to generate an
  improved G-expression.

  ## Parameters
    - prompt: Natural language description of the desired code
    - opts: Options map with:
      - `:max_retries` - Maximum retry attempts (default: 3)
      - `:retry_on` - List of failure steps to retry (default: [:generate, :evaluate, :test])
      - `:backoff_ms` - Base backoff time in milliseconds (default: 100)
      - `:exponential_backoff` - Use exponential backoff (default: true)
      - Plus all options from `generate_and_test/2`

  ## Returns
    - `{:ok, result}` with generation results and retry metrics
    - `{:error, reason}` if all retries exhausted

  ## Examples

      iex> Semanteq.Generator.generate_with_retry("Create a factorial function", %{max_retries: 5})
      {:ok, %{
        prompt: "Create a factorial function",
        gexpr: %{"g" => "lam", ...},
        evaluation: %{result: ...},
        tests: %{passed: 3, failed: 0},
        retry_metrics: %{
          attempts: 2,
          success_on_attempt: 2,
          total_time_ms: 1523,
          retries: [%{attempt: 1, step: :evaluate, error: "..."}]
        }
      }}
  """
  def generate_with_retry(prompt, opts \\ %{}) do
    max_retries = Map.get(opts, :max_retries, @default_max_retries)
    retry_on = Map.get(opts, :retry_on, @default_retry_on)
    backoff_ms = Map.get(opts, :backoff_ms, @default_backoff_ms)
    exponential_backoff = Map.get(opts, :exponential_backoff, true)

    start_time = System.monotonic_time(:millisecond)

    retry_state = %{
      attempts: 0,
      retries: [],
      last_gexpr: nil,
      last_error: nil
    }

    result =
      do_generate_with_retry(
        prompt,
        opts,
        max_retries + 1,
        retry_on,
        backoff_ms,
        exponential_backoff,
        retry_state
      )

    end_time = System.monotonic_time(:millisecond)
    total_time_ms = end_time - start_time

    case result do
      {:ok, generation_result, final_state} ->
        metrics = %{
          attempts: final_state.attempts,
          success_on_attempt: final_state.attempts,
          total_time_ms: total_time_ms,
          retries: Enum.reverse(final_state.retries)
        }

        {:ok, Map.put(generation_result, :retry_metrics, metrics)}

      {:error, reason, final_state} ->
        metrics = %{
          attempts: final_state.attempts,
          success_on_attempt: nil,
          total_time_ms: total_time_ms,
          retries: Enum.reverse(final_state.retries)
        }

        {:error, %{reason: reason, retry_metrics: metrics}}
    end
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

  Note: Consider using `generate_with_retry/2` for more detailed metrics.
  """
  def generate_with_refinement(prompt, opts \\ %{}) do
    # Delegate to the new retry function for backwards compatibility
    case generate_with_retry(prompt, opts) do
      {:ok, result} -> {:ok, Map.delete(result, :retry_metrics)}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, _} = error -> error
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
  Returns the default retry configuration.
  """
  def default_retry_config do
    %{
      max_retries: @default_max_retries,
      retry_on: @default_retry_on,
      backoff_ms: @default_backoff_ms,
      exponential_backoff: true
    }
  end

  @doc """
  Returns the default batch configuration.
  """
  def default_batch_config do
    %{
      parallelism: @default_batch_parallelism,
      stop_on_error: false,
      with_retry: false
    }
  end

  @doc """
  Processes multiple prompts in a batch with parallel execution.

  ## Parameters
    - prompts: List of prompts to process, each can be:
      - A string (prompt text)
      - A map with `:prompt` and optional per-item options
    - opts: Options map with:
      - `:parallelism` - Number of concurrent tasks (default: 5)
      - `:stop_on_error` - Stop batch on first error (default: false)
      - `:with_retry` - Use retry mechanism for each item (default: false)
      - Plus all options from `generate_and_test/2` or `generate_with_retry/2`

  ## Returns
    - `{:ok, batch_result}` with results and summary statistics

  ## Examples

      iex> prompts = [
      ...>   "Create a function that doubles a number",
      ...>   "Create a function that adds two numbers",
      ...>   %{prompt: "Create factorial function", test_inputs: [[5]]}
      ...> ]
      iex> Semanteq.Generator.batch_generate(prompts, %{parallelism: 3})
      {:ok, %{
        total: 3,
        succeeded: 2,
        failed: 1,
        total_time_ms: 5230,
        results: [
          %{index: 0, status: :ok, result: %{...}},
          %{index: 1, status: :ok, result: %{...}},
          %{index: 2, status: :error, error: %{...}}
        ],
        summary: %{
          success_rate: 0.67,
          avg_time_ms: 1743
        }
      }}
  """
  def batch_generate(prompts, opts \\ %{}) when is_list(prompts) do
    parallelism = Map.get(opts, :parallelism, @default_batch_parallelism)
    stop_on_error = Map.get(opts, :stop_on_error, false)
    with_retry = Map.get(opts, :with_retry, false)

    start_time = System.monotonic_time(:millisecond)

    Logger.info(
      "Starting batch generation of #{length(prompts)} prompts with parallelism #{parallelism}"
    )

    # Normalize prompts to a consistent format
    normalized_prompts =
      prompts
      |> Enum.with_index()
      |> Enum.map(fn {prompt, index} ->
        {index, normalize_prompt_item(prompt, opts)}
      end)

    # Process in parallel with controlled concurrency
    results =
      if stop_on_error do
        process_batch_sequential_on_error(normalized_prompts, with_retry, parallelism)
      else
        process_batch_parallel(normalized_prompts, with_retry, parallelism)
      end

    end_time = System.monotonic_time(:millisecond)
    total_time_ms = end_time - start_time

    # Build summary
    batch_result = build_batch_result(results, total_time_ms)

    Logger.info(
      "Batch generation completed: #{batch_result.succeeded}/#{batch_result.total} succeeded in #{total_time_ms}ms"
    )

    {:ok, batch_result}
  end

  @doc """
  Processes a batch from JSON input (for API compatibility).

  Accepts a list of items where each item has at minimum a "prompt" field.

  ## Parameters
    - items: List of maps with "prompt" key and optional configuration
    - opts: Batch options

  ## Returns
    - Same as `batch_generate/2`
  """
  def batch_generate_from_json(items, opts \\ %{}) when is_list(items) do
    prompts =
      Enum.map(items, fn item ->
        prompt = Map.get(item, "prompt") || Map.get(item, :prompt)

        if prompt do
          item_opts =
            item
            |> Map.delete("prompt")
            |> Map.delete(:prompt)
            |> atomize_keys()

          if map_size(item_opts) > 0 do
            Map.put(item_opts, :prompt, prompt)
          else
            prompt
          end
        else
          raise ArgumentError, "Each batch item must have a 'prompt' field"
        end
      end)

    batch_generate(prompts, opts)
  end

  # Private functions

  defp normalize_prompt_item(prompt, base_opts) when is_binary(prompt) do
    %{prompt: prompt, opts: base_opts}
  end

  defp normalize_prompt_item(%{prompt: prompt} = item, base_opts) when is_binary(prompt) do
    item_opts = Map.delete(item, :prompt)
    merged_opts = Map.merge(base_opts, item_opts)
    %{prompt: prompt, opts: merged_opts}
  end

  defp normalize_prompt_item(item, base_opts) when is_map(item) do
    # Handle string keys
    prompt = Map.get(item, "prompt") || Map.get(item, :prompt)

    if prompt do
      item_opts =
        item
        |> Map.delete("prompt")
        |> Map.delete(:prompt)
        |> atomize_keys()

      merged_opts = Map.merge(base_opts, item_opts)
      %{prompt: prompt, opts: merged_opts}
    else
      raise ArgumentError, "Batch item must have a 'prompt' field"
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end

  defp process_batch_parallel(normalized_prompts, with_retry, parallelism) do
    normalized_prompts
    |> Task.async_stream(
      fn {index, %{prompt: prompt, opts: item_opts}} ->
        start_time = System.monotonic_time(:millisecond)

        result =
          if with_retry do
            generate_with_retry(prompt, item_opts)
          else
            generate_and_test(prompt, item_opts)
          end

        end_time = System.monotonic_time(:millisecond)
        duration_ms = end_time - start_time

        case result do
          {:ok, generation_result} ->
            %{
              index: index,
              status: :ok,
              result: generation_result,
              duration_ms: duration_ms
            }

          {:error, reason} ->
            %{
              index: index,
              status: :error,
              error: reason,
              duration_ms: duration_ms
            }
        end
      end,
      max_concurrency: parallelism,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp process_batch_sequential_on_error(normalized_prompts, with_retry, parallelism) do
    # Process in chunks, stopping if any chunk has an error
    normalized_prompts
    |> Enum.chunk_every(parallelism)
    |> Enum.reduce_while([], fn chunk, acc ->
      chunk_results =
        chunk
        |> Task.async_stream(
          fn {index, %{prompt: prompt, opts: item_opts}} ->
            start_time = System.monotonic_time(:millisecond)

            result =
              if with_retry do
                generate_with_retry(prompt, item_opts)
              else
                generate_and_test(prompt, item_opts)
              end

            end_time = System.monotonic_time(:millisecond)
            duration_ms = end_time - start_time

            case result do
              {:ok, generation_result} ->
                %{
                  index: index,
                  status: :ok,
                  result: generation_result,
                  duration_ms: duration_ms
                }

              {:error, reason} ->
                %{
                  index: index,
                  status: :error,
                  error: reason,
                  duration_ms: duration_ms
                }
            end
          end,
          max_concurrency: parallelism,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      has_error = Enum.any?(chunk_results, &(&1.status == :error))

      if has_error do
        {:halt, acc ++ chunk_results}
      else
        {:cont, acc ++ chunk_results}
      end
    end)
  end

  defp build_batch_result(results, total_time_ms) do
    total = length(results)
    succeeded = Enum.count(results, &(&1.status == :ok))
    failed = total - succeeded

    durations =
      results
      |> Enum.filter(&(&1.status == :ok))
      |> Enum.map(& &1.duration_ms)

    avg_time_ms =
      if length(durations) > 0 do
        Enum.sum(durations) / length(durations)
      else
        0
      end

    success_rate =
      if total > 0 do
        Float.round(succeeded / total, 2)
      else
        0.0
      end

    %{
      total: total,
      succeeded: succeeded,
      failed: failed,
      total_time_ms: total_time_ms,
      results: Enum.sort_by(results, & &1.index),
      summary: %{
        success_rate: success_rate,
        avg_time_ms: Float.round(avg_time_ms, 2)
      }
    }
  end

  defp do_generate_with_retry(_prompt, _opts, 0, _retry_on, _backoff_ms, _exp, state) do
    {:error, :max_retries_exceeded, state}
  end

  defp do_generate_with_retry(
         prompt,
         opts,
         retries_left,
         retry_on,
         backoff_ms,
         exp_backoff,
         state
       ) do
    current_attempt = state.attempts + 1
    state = %{state | attempts: current_attempt}

    Logger.debug("Generation attempt #{current_attempt}")

    # If we have a refined gexpr from a previous attempt, use it
    generation_opts =
      if state.last_gexpr do
        # Feed back the error to improve the prompt
        enhanced_prompt = build_enhanced_prompt(prompt, state.last_error)
        Map.put(opts, :enhanced_prompt, enhanced_prompt)
      else
        opts
      end

    prompt_to_use =
      if Map.has_key?(generation_opts, :enhanced_prompt) do
        generation_opts.enhanced_prompt
      else
        prompt
      end

    case generate_and_test(prompt_to_use, Map.delete(generation_opts, :enhanced_prompt)) do
      {:ok, result} ->
        Logger.info("Generation succeeded on attempt #{current_attempt}")
        {:ok, result, state}

      {:error, %{step: step, reason: reason}} ->
        if step in retry_on and retries_left > 1 do
          Logger.warning(
            "Generation failed at #{step} on attempt #{current_attempt}, retrying... (#{retries_left - 1} retries left)"
          )

          # Record this retry attempt
          retry_info = %{
            attempt: current_attempt,
            step: step,
            error: format_error_for_feedback(reason),
            timestamp: DateTime.utc_now()
          }

          state = %{
            state
            | retries: [retry_info | state.retries],
              last_error: %{step: step, reason: reason}
          }

          # Apply backoff
          backoff = calculate_backoff(current_attempt, backoff_ms, exp_backoff)
          Process.sleep(backoff)

          do_generate_with_retry(
            prompt,
            opts,
            retries_left - 1,
            retry_on,
            backoff_ms,
            exp_backoff,
            state
          )
        else
          if step not in retry_on do
            Logger.warning("Generation failed at #{step}, not configured to retry on this step")
          end

          {:error, %{step: step, reason: reason}, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp build_enhanced_prompt(original_prompt, %{step: step, reason: reason}) do
    feedback = build_feedback(step, reason)

    """
    #{original_prompt}

    IMPORTANT: A previous attempt failed with the following error:
    #{feedback}

    Please generate a corrected G-expression that addresses this issue.
    Ensure the expression is syntactically valid and will evaluate correctly.
    """
  end

  defp build_enhanced_prompt(original_prompt, _), do: original_prompt

  defp calculate_backoff(attempt, base_ms, true = _exponential) do
    # Exponential backoff with jitter
    base = base_ms * :math.pow(2, attempt - 1)
    jitter = :rand.uniform(round(base * 0.1))
    round(base + jitter)
  end

  defp calculate_backoff(_attempt, base_ms, false = _exponential) do
    base_ms
  end

  defp format_error_for_feedback(reason) when is_binary(reason), do: reason
  defp format_error_for_feedback(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_error_for_feedback(%{output: output}) when is_binary(output) do
    # Truncate long error outputs
    if String.length(output) > 500 do
      String.slice(output, 0, 500) <> "..."
    else
      output
    end
  end

  defp format_error_for_feedback(reason), do: inspect(reason, limit: 5)

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

  defp build_feedback(:generate, reason) do
    "Failed to generate valid G-expression: #{format_error_for_feedback(reason)}"
  end

  defp build_feedback(:evaluate, reason) do
    "G-expression evaluation failed: #{format_error_for_feedback(reason)}"
  end

  defp build_feedback(:test, reason) do
    "Tests failed: #{format_error_for_feedback(reason)}"
  end

  defp build_feedback(_step, reason) do
    "Error: #{format_error_for_feedback(reason)}"
  end
end
