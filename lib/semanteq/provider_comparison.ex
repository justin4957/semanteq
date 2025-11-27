defmodule Semanteq.ProviderComparison do
  @moduledoc """
  Multi-provider comparison for G-Lisp code generation.

  This module enables running the same prompt against multiple LLM providers
  simultaneously and comparing the results. It provides:

  - Parallel execution across providers
  - G-expression equivalence analysis
  - Performance metrics (latency, token usage)
  - Visual diff of generated expressions
  - Comparison reports

  ## Usage

      # Compare generation across all available providers
      {:ok, comparison} = Semanteq.ProviderComparison.compare(
        "Create a function that doubles a number",
        providers: [:anthropic, :openai, :ollama]
      )

      # The comparison includes:
      # - Results from each provider
      # - Equivalence analysis
      # - Performance metrics
      # - Recommendations

  ## Comparison Options

  - `:providers` - List of provider names to use (default: all registered)
  - `:timeout_ms` - Timeout per provider in milliseconds (default: 60000)
  - `:parallel` - Run providers in parallel (default: true)
  - `:test_inputs` - Inputs to test equivalence (default: auto-generated)
  - `:include_evaluation` - Include G-Lisp evaluation results (default: true)
  """

  require Logger

  alias Semanteq.{Provider, Glisp}

  @default_timeout_ms 60_000
  @default_test_inputs [[1], [2], [5], [10], [-1], [0]]

  @doc """
  Compares G-expression generation across multiple providers.

  Runs the same prompt against each specified provider (in parallel by default)
  and compares the results for equivalence and performance.

  ## Parameters
    - prompt: Natural language description of the desired code
    - opts: Options keyword list
      - `:providers` - List of provider atoms (default: all registered)
      - `:timeout_ms` - Timeout per provider (default: 60000)
      - `:parallel` - Run in parallel (default: true)
      - `:test_inputs` - Inputs for equivalence testing
      - `:include_evaluation` - Include eval results (default: true)

  ## Returns
    - `{:ok, comparison}` with full comparison results
    - `{:error, reason}` on failure

  ## Example

      {:ok, result} = Semanteq.ProviderComparison.compare(
        "Create a factorial function",
        providers: [:anthropic, :openai],
        test_inputs: [[5], [6], [7]]
      )
  """
  def compare(prompt, opts \\ []) do
    providers = Keyword.get(opts, :providers, available_providers())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    parallel = Keyword.get(opts, :parallel, true)
    test_inputs = Keyword.get(opts, :test_inputs, @default_test_inputs)
    include_evaluation = Keyword.get(opts, :include_evaluation, true)

    Logger.info("Starting provider comparison for #{length(providers)} providers")
    start_time = System.monotonic_time(:millisecond)

    # Execute generation on each provider
    results =
      if parallel do
        execute_parallel(prompt, providers, timeout_ms)
      else
        execute_sequential(prompt, providers, timeout_ms)
      end

    # Evaluate results if requested
    results_with_eval =
      if include_evaluation do
        add_evaluations(results, test_inputs)
      else
        results
      end

    # Analyze equivalence
    equivalence_analysis = analyze_equivalence(results_with_eval, test_inputs)

    # Calculate performance metrics
    performance_metrics = calculate_performance_metrics(results_with_eval)

    # Generate recommendations
    recommendations = generate_recommendations(results_with_eval, equivalence_analysis)

    total_time = System.monotonic_time(:millisecond) - start_time

    comparison = %{
      prompt: prompt,
      providers_compared: providers,
      results: results_with_eval,
      equivalence: equivalence_analysis,
      performance: performance_metrics,
      recommendations: recommendations,
      summary: generate_summary(results_with_eval, equivalence_analysis),
      total_time_ms: total_time,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Logger.info("Provider comparison completed in #{total_time}ms")
    {:ok, comparison}
  end

  @doc """
  Returns list of currently available providers that can be used for comparison.

  Only returns providers that pass their health check.
  """
  def available_providers do
    Provider.registered_providers()
    |> Map.keys()
    |> Enum.filter(&provider_available?/1)
  end

  @doc """
  Checks if a specific provider is available for comparison.
  """
  def provider_available?(provider_name) do
    module = Map.get(Provider.registered_providers(), provider_name)

    if module do
      case module.health_check() do
        {:ok, _} -> true
        {:error, _} -> false
      end
    else
      false
    end
  end

  @doc """
  Generates a visual diff of two G-expressions.

  Returns a structured diff showing differences between expressions.
  """
  def diff_gexprs(gexpr_a, gexpr_b) do
    diff_recursive(gexpr_a, gexpr_b, [])
  end

  @doc """
  Compares performance metrics between two providers.

  Returns a comparison showing which provider performed better.
  """
  def compare_performance(result_a, result_b) do
    %{
      latency_difference_ms: result_a.latency_ms - result_b.latency_ms,
      faster_provider:
        if(result_a.latency_ms < result_b.latency_ms,
          do: result_a.provider,
          else: result_b.provider
        ),
      latency_ratio:
        if(result_b.latency_ms > 0,
          do: Float.round(result_a.latency_ms / result_b.latency_ms, 2),
          else: nil
        )
    }
  end

  @doc """
  Default configuration for provider comparison.
  """
  def default_config do
    %{
      timeout_ms: @default_timeout_ms,
      parallel: true,
      include_evaluation: true,
      test_inputs: @default_test_inputs
    }
  end

  # ============================================================================
  # Private Functions - Execution
  # ============================================================================

  defp execute_parallel(prompt, providers, timeout_ms) do
    providers
    |> Enum.map(fn provider ->
      Task.async(fn ->
        execute_single_provider(prompt, provider, timeout_ms)
      end)
    end)
    |> Task.await_many(timeout_ms + 5000)
  end

  defp execute_sequential(prompt, providers, timeout_ms) do
    Enum.map(providers, fn provider ->
      execute_single_provider(prompt, provider, timeout_ms)
    end)
  end

  defp execute_single_provider(prompt, provider_name, timeout_ms) do
    module = Map.get(Provider.registered_providers(), provider_name)

    if is_nil(module) do
      %{
        provider: provider_name,
        status: :error,
        error: :unknown_provider,
        gexpr: nil,
        latency_ms: 0
      }
    else
      start_time = System.monotonic_time(:millisecond)

      result =
        try do
          task =
            Task.async(fn ->
              module.generate_gexpr(prompt, [])
            end)

          Task.await(task, timeout_ms)
        catch
          :exit, {:timeout, _} ->
            {:error, :timeout}

          kind, reason ->
            {:error, {kind, reason}}
        end

      latency_ms = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, gexpr} ->
          %{
            provider: provider_name,
            status: :success,
            gexpr: gexpr,
            latency_ms: latency_ms,
            error: nil
          }

        {:error, reason} ->
          %{
            provider: provider_name,
            status: :error,
            error: reason,
            gexpr: nil,
            latency_ms: latency_ms
          }
      end
    end
  end

  # ============================================================================
  # Private Functions - Evaluation
  # ============================================================================

  defp add_evaluations(results, test_inputs) do
    Enum.map(results, fn result ->
      if result.status == :success and result.gexpr do
        evaluations = evaluate_with_inputs(result.gexpr, test_inputs)
        Map.put(result, :evaluations, evaluations)
      else
        Map.put(result, :evaluations, [])
      end
    end)
  end

  defp evaluate_with_inputs(gexpr, test_inputs) do
    Enum.map(test_inputs, fn inputs ->
      # Build a function application with the gexpr and inputs
      app_gexpr = build_application(gexpr, inputs)

      case Glisp.eval(app_gexpr) do
        {:ok, result} ->
          %{inputs: inputs, result: result, status: :success}

        {:error, reason} ->
          %{inputs: inputs, error: reason, status: :error}
      end
    end)
  end

  defp build_application(gexpr, inputs) do
    args = Enum.map(inputs, fn input -> %{"g" => "lit", "v" => input} end)

    %{
      "g" => "app",
      "v" => %{
        "fn" => gexpr,
        "args" => args
      }
    }
  end

  # ============================================================================
  # Private Functions - Equivalence Analysis
  # ============================================================================

  defp analyze_equivalence(results, test_inputs) do
    successful_results = Enum.filter(results, &(&1.status == :success))

    if length(successful_results) < 2 do
      %{
        can_compare: false,
        reason: "Need at least 2 successful results to compare",
        pairs: [],
        all_equivalent: false
      }
    else
      pairs = generate_pairs(successful_results)

      pair_comparisons =
        Enum.map(pairs, fn {result_a, result_b} ->
          compare_pair(result_a, result_b, test_inputs)
        end)

      all_equivalent = Enum.all?(pair_comparisons, & &1.equivalent)

      %{
        can_compare: true,
        pairs: pair_comparisons,
        all_equivalent: all_equivalent,
        equivalent_groups: group_equivalent_results(successful_results, pair_comparisons)
      }
    end
  end

  defp generate_pairs(results) do
    for i <- 0..(length(results) - 2),
        j <- (i + 1)..(length(results) - 1) do
      {Enum.at(results, i), Enum.at(results, j)}
    end
  end

  defp compare_pair(result_a, result_b, _test_inputs) do
    # Check structural equivalence
    structural_equivalent = structurally_equivalent?(result_a.gexpr, result_b.gexpr)

    # Check behavioral equivalence (same outputs for same inputs)
    evals_a = Map.get(result_a, :evaluations, [])
    evals_b = Map.get(result_b, :evaluations, [])

    behavioral_results =
      Enum.zip(evals_a, evals_b)
      |> Enum.map(fn {eval_a, eval_b} ->
        outputs_match?(eval_a, eval_b)
      end)

    behavioral_equivalent =
      if length(behavioral_results) > 0 do
        Enum.all?(behavioral_results, & &1)
      else
        # If no evaluations, fall back to structural equivalence
        structural_equivalent
      end

    # Generate diff if not structurally equivalent
    diff =
      if structural_equivalent do
        nil
      else
        diff_gexprs(result_a.gexpr, result_b.gexpr)
      end

    %{
      provider_a: result_a.provider,
      provider_b: result_b.provider,
      structural_equivalent: structural_equivalent,
      behavioral_equivalent: behavioral_equivalent,
      equivalent: behavioral_equivalent,
      diff: diff,
      test_results: behavioral_results
    }
  end

  defp structurally_equivalent?(gexpr_a, gexpr_b) do
    normalize_gexpr(gexpr_a) == normalize_gexpr(gexpr_b)
  end

  defp normalize_gexpr(gexpr) when is_map(gexpr) do
    # Remove metadata for comparison
    gexpr
    |> Map.delete("m")
    |> Enum.map(fn {k, v} -> {k, normalize_gexpr(v)} end)
    |> Enum.sort()
    |> Map.new()
  end

  defp normalize_gexpr(gexpr) when is_list(gexpr) do
    Enum.map(gexpr, &normalize_gexpr/1)
  end

  defp normalize_gexpr(gexpr), do: gexpr

  defp outputs_match?(%{status: :success, result: result_a}, %{status: :success, result: result_b}) do
    result_a == result_b
  end

  defp outputs_match?(_, _), do: false

  defp group_equivalent_results(results, pair_comparisons) do
    # Build equivalence groups using union-find style grouping
    groups = Enum.map(results, fn r -> [r.provider] end)

    Enum.reduce(pair_comparisons, groups, fn comparison, acc ->
      if comparison.equivalent do
        merge_groups(acc, comparison.provider_a, comparison.provider_b)
      else
        acc
      end
    end)
    |> Enum.uniq()
  end

  defp merge_groups(groups, provider_a, provider_b) do
    group_a = Enum.find(groups, fn g -> provider_a in g end)
    group_b = Enum.find(groups, fn g -> provider_b in g end)

    if group_a == group_b do
      groups
    else
      merged = Enum.uniq(group_a ++ group_b)

      groups
      |> Enum.reject(fn g -> g == group_a or g == group_b end)
      |> Kernel.++([merged])
    end
  end

  # ============================================================================
  # Private Functions - Performance Metrics
  # ============================================================================

  defp calculate_performance_metrics(results) do
    successful = Enum.filter(results, &(&1.status == :success))
    failed = Enum.filter(results, &(&1.status == :error))

    latencies = Enum.map(successful, & &1.latency_ms)

    %{
      total_providers: length(results),
      successful_count: length(successful),
      failed_count: length(failed),
      latency_stats:
        if length(latencies) > 0 do
          %{
            min_ms: Enum.min(latencies),
            max_ms: Enum.max(latencies),
            avg_ms: Float.round(Enum.sum(latencies) / length(latencies), 2),
            median_ms: calculate_median(latencies)
          }
        else
          nil
        end,
      fastest_provider:
        if length(successful) > 0 do
          Enum.min_by(successful, & &1.latency_ms).provider
        else
          nil
        end,
      slowest_provider:
        if length(successful) > 0 do
          Enum.max_by(successful, & &1.latency_ms).provider
        else
          nil
        end,
      provider_latencies:
        Enum.map(results, fn r ->
          %{provider: r.provider, latency_ms: r.latency_ms, status: r.status}
        end)
    }
  end

  defp calculate_median([]), do: 0

  defp calculate_median(list) do
    sorted = Enum.sort(list)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  # ============================================================================
  # Private Functions - Diff Generation
  # ============================================================================

  defp diff_recursive(a, b, path) when is_map(a) and is_map(b) do
    all_keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))

    Enum.flat_map(all_keys, fn key ->
      new_path = path ++ [key]
      val_a = Map.get(a, key)
      val_b = Map.get(b, key)

      cond do
        is_nil(val_a) ->
          [%{path: new_path, type: :added, value: val_b}]

        is_nil(val_b) ->
          [%{path: new_path, type: :removed, value: val_a}]

        val_a == val_b ->
          []

        true ->
          diff_recursive(val_a, val_b, new_path)
      end
    end)
  end

  defp diff_recursive(a, b, path) when is_list(a) and is_list(b) do
    max_len = max(length(a), length(b))

    0..(max_len - 1)
    |> Enum.flat_map(fn i ->
      new_path = path ++ [i]
      val_a = Enum.at(a, i)
      val_b = Enum.at(b, i)

      cond do
        is_nil(val_a) ->
          [%{path: new_path, type: :added, value: val_b}]

        is_nil(val_b) ->
          [%{path: new_path, type: :removed, value: val_a}]

        val_a == val_b ->
          []

        true ->
          diff_recursive(val_a, val_b, new_path)
      end
    end)
  end

  defp diff_recursive(a, b, path) when a != b do
    [%{path: path, type: :changed, old_value: a, new_value: b}]
  end

  defp diff_recursive(_, _, _), do: []

  # ============================================================================
  # Private Functions - Recommendations & Summary
  # ============================================================================

  defp generate_recommendations(results, equivalence_analysis) do
    recommendations = []

    # Performance recommendation
    successful = Enum.filter(results, &(&1.status == :success))

    recommendations =
      if length(successful) > 0 do
        fastest = Enum.min_by(successful, & &1.latency_ms)

        recommendations ++
          [
            %{
              type: :performance,
              recommendation: "#{fastest.provider} was fastest at #{fastest.latency_ms}ms",
              provider: fastest.provider
            }
          ]
      else
        recommendations
      end

    # Equivalence recommendation
    recommendations =
      if equivalence_analysis.can_compare do
        if equivalence_analysis.all_equivalent do
          recommendations ++
            [
              %{
                type: :equivalence,
                recommendation: "All providers generated behaviorally equivalent code",
                confidence: :high
              }
            ]
        else
          non_equivalent_pairs =
            equivalence_analysis.pairs
            |> Enum.filter(&(not &1.equivalent))

          recommendations ++
            [
              %{
                type: :equivalence,
                recommendation:
                  "#{length(non_equivalent_pairs)} provider pairs generated different results",
                confidence: :medium,
                details: Enum.map(non_equivalent_pairs, &{&1.provider_a, &1.provider_b})
              }
            ]
        end
      else
        recommendations
      end

    # Reliability recommendation
    failed = Enum.filter(results, &(&1.status == :error))

    recommendations =
      if length(failed) > 0 do
        recommendations ++
          [
            %{
              type: :reliability,
              recommendation:
                "#{length(failed)} provider(s) failed: #{inspect(Enum.map(failed, & &1.provider))}",
              failed_providers: Enum.map(failed, & &1.provider)
            }
          ]
      else
        recommendations
      end

    recommendations
  end

  defp generate_summary(results, equivalence_analysis) do
    successful_count = Enum.count(results, &(&1.status == :success))
    total_count = length(results)

    base_summary = "#{successful_count}/#{total_count} providers succeeded"

    equivalence_summary =
      if equivalence_analysis.can_compare do
        if equivalence_analysis.all_equivalent do
          "; all results equivalent"
        else
          "; results differ between some providers"
        end
      else
        ""
      end

    base_summary <> equivalence_summary
  end
end
