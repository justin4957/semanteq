defmodule Semanteq.Tracer do
  @moduledoc """
  Trace capture and analysis for G-expression execution.

  Provides detailed execution traces with configurable levels and analysis
  capabilities for debugging and understanding G-expression evaluation.

  ## Trace Levels

  - `:minimal` - Only captures final result and error states
  - `:standard` - Captures key evaluation steps and intermediate results (default)
  - `:verbose` - Captures all evaluation steps including internal operations

  ## Example

      {:ok, result} = Tracer.eval_with_trace(gexpr, %{level: :verbose})
      # result contains both the evaluation result and detailed trace

      {:ok, diff} = Tracer.compare_traces(trace_a, trace_b)
      # diff contains step-by-step comparison
  """

  require Logger

  alias Semanteq.Glisp

  @trace_levels [:minimal, :standard, :verbose]
  @default_trace_level :standard

  @doc """
  Returns the available trace levels and their descriptions.
  """
  def trace_levels do
    %{
      minimal: %{
        description: "Only captures final result and error states",
        captures: [:result, :error, :duration_ms]
      },
      standard: %{
        description: "Captures key evaluation steps and intermediate results",
        captures: [:result, :error, :duration_ms, :steps, :env_snapshots]
      },
      verbose: %{
        description: "Captures all evaluation steps including internal operations",
        captures: [
          :result,
          :error,
          :duration_ms,
          :steps,
          :env_snapshots,
          :stack_frames,
          :memory_usage
        ]
      }
    }
  end

  @doc """
  Returns the default trace configuration.
  """
  def default_config do
    %{
      level: @default_trace_level,
      include_source: true,
      include_timestamps: true,
      max_depth: 100
    }
  end

  @doc """
  Evaluates a G-expression with trace capture.

  ## Parameters
    - gexpr: The G-expression to evaluate
    - opts: Options map with:
      - `:level` - Trace level (:minimal, :standard, :verbose)
      - `:include_source` - Include source expression in trace (default: true)
      - `:include_timestamps` - Include timestamps for each step (default: true)
      - `:max_depth` - Maximum trace depth (default: 100)

  ## Returns
    - `{:ok, %{result: any, trace: trace_data}}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> Tracer.eval_with_trace(%{"g" => "lit", "v" => 42}, %{level: :standard})
      {:ok, %{
        result: 42,
        trace: %{
          level: :standard,
          steps: [...],
          duration_ms: 15,
          step_count: 1
        }
      }}
  """
  def eval_with_trace(gexpr, opts \\ %{}) do
    level = validate_level(Map.get(opts, :level, @default_trace_level))
    include_source = Map.get(opts, :include_source, true)
    include_timestamps = Map.get(opts, :include_timestamps, true)
    max_depth = Map.get(opts, :max_depth, 100)

    start_time = System.monotonic_time(:millisecond)

    case Glisp.eval_with_trace(gexpr, %{level: level}) do
      {:ok, %{"result" => result, "trace" => raw_trace}} ->
        end_time = System.monotonic_time(:millisecond)
        duration_ms = end_time - start_time

        trace =
          process_trace(raw_trace, %{
            level: level,
            include_source: include_source,
            include_timestamps: include_timestamps,
            max_depth: max_depth,
            duration_ms: duration_ms,
            source_expr: if(include_source, do: gexpr, else: nil)
          })

        {:ok, %{result: result, trace: trace}}

      {:ok, result} when is_map(result) ->
        # Handle case where trace might be structured differently
        end_time = System.monotonic_time(:millisecond)
        duration_ms = end_time - start_time

        trace = build_minimal_trace(result, gexpr, duration_ms, level, include_source)
        eval_result = Map.get(result, "result", Map.get(result, :result, result))

        {:ok, %{result: eval_result, trace: trace}}

      {:ok, result} ->
        # Plain result without trace structure
        end_time = System.monotonic_time(:millisecond)
        duration_ms = end_time - start_time

        trace = build_minimal_trace(%{result: result}, gexpr, duration_ms, level, include_source)

        {:ok, %{result: result, trace: trace}}

      {:error, reason} ->
        end_time = System.monotonic_time(:millisecond)
        duration_ms = end_time - start_time

        trace = %{
          level: level,
          status: :error,
          error: format_error(reason),
          duration_ms: duration_ms,
          source_expr: if(include_source, do: gexpr, else: nil)
        }

        {:error, %{reason: reason, trace: trace}}
    end
  end

  @doc """
  Compares two execution traces to identify differences.

  Useful for debugging why two semantically similar expressions produce
  different results or take different execution paths.

  ## Parameters
    - trace_a: First trace (from eval_with_trace)
    - trace_b: Second trace (from eval_with_trace)
    - opts: Options map with:
      - `:ignore_timing` - Ignore timing differences (default: true)
      - `:compare_steps` - Compare individual steps (default: true)

  ## Returns
    - `{:ok, comparison}` with detailed diff
    - `{:error, reason}` on failure

  ## Examples

      iex> Tracer.compare_traces(trace_a, trace_b)
      {:ok, %{
        equivalent: false,
        differences: [
          %{step: 3, type: :value_mismatch, a: 10, b: 15}
        ],
        summary: %{
          steps_a: 5,
          steps_b: 6,
          first_divergence: 3
        }
      }}
  """
  def compare_traces(trace_a, trace_b, opts \\ %{}) do
    ignore_timing = Map.get(opts, :ignore_timing, true)
    compare_steps = Map.get(opts, :compare_steps, true)

    differences = []

    # Compare basic properties
    differences =
      if trace_a[:level] != trace_b[:level] do
        [%{type: :level_mismatch, a: trace_a[:level], b: trace_b[:level]} | differences]
      else
        differences
      end

    differences =
      if trace_a[:status] != trace_b[:status] do
        [%{type: :status_mismatch, a: trace_a[:status], b: trace_b[:status]} | differences]
      else
        differences
      end

    # Compare timing if not ignored
    differences =
      if not ignore_timing and trace_a[:duration_ms] != trace_b[:duration_ms] do
        [
          %{type: :timing_difference, a: trace_a[:duration_ms], b: trace_b[:duration_ms]}
          | differences
        ]
      else
        differences
      end

    # Compare steps if enabled
    {step_differences, first_divergence} =
      if compare_steps do
        compare_trace_steps(
          Map.get(trace_a, :steps, []),
          Map.get(trace_b, :steps, [])
        )
      else
        {[], nil}
      end

    differences = differences ++ step_differences

    summary = %{
      steps_a: length(Map.get(trace_a, :steps, [])),
      steps_b: length(Map.get(trace_b, :steps, [])),
      step_count_a: Map.get(trace_a, :step_count, 0),
      step_count_b: Map.get(trace_b, :step_count, 0),
      first_divergence: first_divergence,
      total_differences: length(differences)
    }

    {:ok,
     %{
       equivalent: Enum.empty?(differences),
       differences: Enum.reverse(differences),
       summary: summary
     }}
  end

  @doc """
  Analyzes a trace to extract insights and statistics.

  ## Parameters
    - trace: A trace from eval_with_trace
    - opts: Analysis options

  ## Returns
    - `{:ok, analysis}` with trace statistics and insights
  """
  def analyze_trace(trace, opts \\ %{}) do
    include_hotspots = Map.get(opts, :include_hotspots, true)

    steps = Map.get(trace, :steps, [])
    step_count = Map.get(trace, :step_count, length(steps))

    # Calculate step type distribution
    step_types =
      steps
      |> Enum.map(&Map.get(&1, :type, :unknown))
      |> Enum.frequencies()

    # Find deepest nesting
    max_depth =
      steps
      |> Enum.map(&Map.get(&1, :depth, 0))
      |> Enum.max(fn -> 0 end)

    # Identify potential hotspots (repeated operations)
    hotspots =
      if include_hotspots do
        steps
        |> Enum.filter(&Map.get(&1, :repeated, false))
        |> Enum.take(10)
      else
        []
      end

    analysis = %{
      total_steps: step_count,
      step_type_distribution: step_types,
      max_depth: max_depth,
      duration_ms: Map.get(trace, :duration_ms, 0),
      level: Map.get(trace, :level, :unknown),
      status: Map.get(trace, :status, :unknown),
      hotspots: hotspots,
      insights: generate_insights(trace, step_types, max_depth)
    }

    {:ok, analysis}
  end

  @doc """
  Formats a trace for human-readable output.

  ## Parameters
    - trace: A trace from eval_with_trace
    - opts: Formatting options with :format (:text, :json, :markdown)

  ## Returns
    - Formatted string representation
  """
  def format_trace(trace, opts \\ %{}) do
    format = Map.get(opts, :format, :json)

    case format do
      :json ->
        Jason.encode!(trace, pretty: true)

      :text ->
        format_trace_as_text(trace)

      :markdown ->
        format_trace_as_markdown(trace)
    end
  end

  # Private functions

  defp validate_level(level) when level in @trace_levels, do: level
  defp validate_level(_), do: @default_trace_level

  defp process_trace(raw_trace, opts) when is_map(raw_trace) do
    steps = normalize_steps(Map.get(raw_trace, "steps", Map.get(raw_trace, :steps, [])))

    %{
      level: opts.level,
      status: :success,
      steps: if(opts.max_depth, do: Enum.take(steps, opts.max_depth), else: steps),
      step_count: length(steps),
      duration_ms: opts.duration_ms,
      source_expr: opts.source_expr,
      env_snapshots: Map.get(raw_trace, "env_snapshots", Map.get(raw_trace, :env_snapshots, [])),
      metadata: %{
        captured_at: if(opts.include_timestamps, do: DateTime.utc_now(), else: nil),
        trace_version: "1.0"
      }
    }
  end

  defp process_trace(raw_trace, opts) when is_list(raw_trace) do
    process_trace(%{steps: raw_trace}, opts)
  end

  defp process_trace(_, opts) do
    %{
      level: opts.level,
      status: :success,
      steps: [],
      step_count: 0,
      duration_ms: opts.duration_ms,
      source_expr: opts.source_expr,
      metadata: %{
        captured_at: if(opts.include_timestamps, do: DateTime.utc_now(), else: nil),
        trace_version: "1.0"
      }
    }
  end

  defp build_minimal_trace(result, source_expr, duration_ms, level, include_source) do
    %{
      level: level,
      status: :success,
      steps: [],
      step_count: 0,
      duration_ms: duration_ms,
      source_expr: if(include_source, do: source_expr, else: nil),
      result_summary: summarize_result(result),
      metadata: %{
        captured_at: DateTime.utc_now(),
        trace_version: "1.0"
      }
    }
  end

  defp normalize_steps(steps) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      normalize_step(step, index)
    end)
  end

  defp normalize_steps(_), do: []

  defp normalize_step(step, index) when is_map(step) do
    %{
      index: index,
      type: Map.get(step, "type", Map.get(step, :type, :eval)),
      expression: Map.get(step, "expression", Map.get(step, :expression)),
      result: Map.get(step, "result", Map.get(step, :result)),
      depth: Map.get(step, "depth", Map.get(step, :depth, 0)),
      timestamp: Map.get(step, "timestamp", Map.get(step, :timestamp))
    }
  end

  defp normalize_step(step, index) do
    %{
      index: index,
      type: :unknown,
      expression: step,
      result: nil,
      depth: 0
    }
  end

  defp compare_trace_steps(steps_a, steps_b) do
    max_len = max(length(steps_a), length(steps_b))

    if max_len == 0 do
      {[], nil}
    else
      compare_trace_steps_range(steps_a, steps_b, max_len)
    end
  end

  defp compare_trace_steps_range(steps_a, steps_b, max_len) do
    {differences, first_divergence} =
      Enum.reduce(0..(max_len - 1), {[], nil}, fn index, {diffs, first_div} ->
        step_a = Enum.at(steps_a, index)
        step_b = Enum.at(steps_b, index)

        cond do
          is_nil(step_a) ->
            diff = %{step: index, type: :missing_in_a, b: step_b}
            first = if is_nil(first_div), do: index, else: first_div
            {[diff | diffs], first}

          is_nil(step_b) ->
            diff = %{step: index, type: :missing_in_b, a: step_a}
            first = if is_nil(first_div), do: index, else: first_div
            {[diff | diffs], first}

          step_a[:result] != step_b[:result] ->
            diff = %{step: index, type: :value_mismatch, a: step_a[:result], b: step_b[:result]}
            first = if is_nil(first_div), do: index, else: first_div
            {[diff | diffs], first}

          step_a[:type] != step_b[:type] ->
            diff = %{step: index, type: :type_mismatch, a: step_a[:type], b: step_b[:type]}
            first = if is_nil(first_div), do: index, else: first_div
            {[diff | diffs], first}

          true ->
            {diffs, first_div}
        end
      end)

    {Enum.reverse(differences), first_divergence}
  end

  defp summarize_result(result) when is_map(result) do
    case Map.get(result, "result", Map.get(result, :result)) do
      nil -> %{type: :map, size: map_size(result)}
      val -> %{type: type_of(val), value: val}
    end
  end

  defp summarize_result(result), do: %{type: type_of(result), value: result}

  defp type_of(val) when is_integer(val), do: :integer
  defp type_of(val) when is_float(val), do: :float
  defp type_of(val) when is_binary(val), do: :string
  defp type_of(val) when is_boolean(val), do: :boolean
  defp type_of(val) when is_list(val), do: :list
  defp type_of(val) when is_map(val), do: :map
  defp type_of(nil), do: nil
  defp type_of(_), do: :unknown

  defp generate_insights(trace, step_types, max_depth) do
    insights = []

    # Depth insight
    insights =
      if max_depth > 10 do
        [
          "Deep nesting detected (depth: #{max_depth}). Consider simplifying the expression."
          | insights
        ]
      else
        insights
      end

    # Check for many application steps
    app_count = Map.get(step_types, :app, 0) + Map.get(step_types, "app", 0)

    insights =
      if app_count > 50 do
        [
          "High function application count (#{app_count}). May indicate recursive or iterative computation."
          | insights
        ]
      else
        insights
      end

    # Duration insight
    duration = Map.get(trace, :duration_ms, 0)

    insights =
      if duration > 1000 do
        [
          "Long execution time (#{duration}ms). Consider optimizing or caching results."
          | insights
        ]
      else
        insights
      end

    Enum.reverse(insights)
  end

  defp format_trace_as_text(trace) do
    """
    === Trace Report ===
    Level: #{trace[:level]}
    Status: #{trace[:status]}
    Duration: #{trace[:duration_ms]}ms
    Steps: #{trace[:step_count]}

    #{format_steps_as_text(trace[:steps] || [])}
    """
  end

  defp format_steps_as_text(steps) do
    steps
    |> Enum.map(fn step ->
      "  [#{step[:index]}] #{step[:type]}: #{inspect(step[:result])}"
    end)
    |> Enum.join("\n")
  end

  defp format_trace_as_markdown(trace) do
    """
    # Trace Report

    | Property | Value |
    |----------|-------|
    | Level | #{trace[:level]} |
    | Status | #{trace[:status]} |
    | Duration | #{trace[:duration_ms]}ms |
    | Steps | #{trace[:step_count]} |

    ## Steps

    #{format_steps_as_markdown(trace[:steps] || [])}
    """
  end

  defp format_steps_as_markdown(steps) do
    steps
    |> Enum.map(fn step ->
      "- **Step #{step[:index]}** (#{step[:type]}): `#{inspect(step[:result])}`"
    end)
    |> Enum.join("\n")
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(%{output: output}), do: output
  defp format_error(error), do: inspect(error)
end
