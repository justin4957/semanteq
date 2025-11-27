defmodule Semanteq.PropertyTester do
  @moduledoc """
  Property-based testing for G-expressions.

  Generates test cases based on mathematical and logical properties to validate
  that generated G-expressions satisfy specified constraints.

  ## Supported Properties

  - `:identity` - f(identity_element, x) == x (e.g., 0 for addition, 1 for multiplication)
  - `:commutativity` - f(a, b) == f(b, a)
  - `:associativity` - f(f(a, b), c) == f(a, f(b, c))
  - `:idempotence` - f(x, x) == x (for operations like min, max, or)
  - `:inverse` - f(x, inverse(x)) == identity (e.g., x + (-x) == 0)
  - `:distributivity` - f(a, g(b, c)) == g(f(a, b), f(a, c))
  - `:monotonicity` - a <= b implies f(a) <= f(b)
  - `:boundedness` - min <= f(x) <= max for all x in domain

  ## Example

      property = %{
        type: :commutativity,
        description: "Addition is commutative"
      }

      {:ok, result} = PropertyTester.test_property(gexpr, property, %{iterations: 100})
  """

  require Logger

  alias Semanteq.Glisp

  @default_iterations 100
  @default_min_value -1000
  @default_max_value 1000

  # Property type definitions with their test generators
  @property_schemas %{
    identity: %{
      description: "Identity property: f(identity, x) == x",
      required_params: [:identity_element],
      arity: 2
    },
    commutativity: %{
      description: "Commutativity: f(a, b) == f(b, a)",
      required_params: [],
      arity: 2
    },
    associativity: %{
      description: "Associativity: f(f(a, b), c) == f(a, f(b, c))",
      required_params: [],
      arity: 2
    },
    idempotence: %{
      description: "Idempotence: f(x, x) == x",
      required_params: [],
      arity: 2
    },
    inverse: %{
      description: "Inverse: f(x, inverse(x)) == identity",
      required_params: [:identity_element, :inverse_fn],
      arity: 2
    },
    distributivity: %{
      description: "Distributivity: f(a, g(b, c)) == g(f(a, b), f(a, c))",
      required_params: [:outer_fn],
      arity: 2
    },
    monotonicity: %{
      description: "Monotonicity: a <= b implies f(a) <= f(b)",
      required_params: [],
      arity: 1
    },
    boundedness: %{
      description: "Boundedness: min <= f(x) <= max",
      required_params: [:min_bound, :max_bound],
      arity: 1
    }
  }

  @doc """
  Returns available property schemas with their descriptions and required parameters.
  """
  def available_properties do
    @property_schemas
  end

  @doc """
  Returns the default property testing configuration.
  """
  def default_config do
    %{
      iterations: @default_iterations,
      min_value: @default_min_value,
      max_value: @default_max_value,
      seed: nil,
      value_type: :integer
    }
  end

  @doc """
  Tests a G-expression against a specified property.

  ## Parameters
    - gexpr: The G-expression to test (should be a function)
    - property: Property specification map with:
      - `:type` - Property type (atom from available_properties)
      - Additional parameters as required by the property type
    - opts: Options map with:
      - `:iterations` - Number of test iterations (default: 100)
      - `:min_value` - Minimum value for random inputs (default: -1000)
      - `:max_value` - Maximum value for random inputs (default: 1000)
      - `:seed` - Random seed for reproducibility
      - `:value_type` - Type of values to generate (:integer, :float)

  ## Returns
    - `{:ok, result}` with test results including pass/fail status and counterexamples
    - `{:error, reason}` on failure

  ## Examples

      # Test commutativity
      {:ok, result} = PropertyTester.test_property(
        add_gexpr,
        %{type: :commutativity},
        %{iterations: 50}
      )

      # Test identity property
      {:ok, result} = PropertyTester.test_property(
        add_gexpr,
        %{type: :identity, identity_element: 0},
        %{iterations: 100}
      )
  """
  def test_property(gexpr, property, opts \\ %{}) do
    property_type = Map.get(property, :type)

    case validate_property(property_type, property) do
      :ok ->
        run_property_test(gexpr, property_type, property, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Tests a G-expression against multiple properties.

  ## Parameters
    - gexpr: The G-expression to test
    - properties: List of property specifications
    - opts: Options (same as test_property/3)

  ## Returns
    - `{:ok, results}` with aggregated test results
  """
  def test_properties(gexpr, properties, opts \\ %{}) when is_list(properties) do
    start_time = System.monotonic_time(:millisecond)

    results =
      Enum.map(properties, fn property ->
        case test_property(gexpr, property, opts) do
          {:ok, result} ->
            %{property: property, status: :ok, result: result}

          {:error, reason} ->
            %{property: property, status: :error, error: reason}
        end
      end)

    end_time = System.monotonic_time(:millisecond)

    passed = Enum.count(results, &(&1.status == :ok and &1.result.passed))
    failed = Enum.count(results, &(&1.status == :ok and not &1.result.passed))
    errors = Enum.count(results, &(&1.status == :error))

    summary = %{
      total: length(results),
      passed: passed,
      failed: failed,
      errors: errors,
      total_time_ms: end_time - start_time,
      results: results
    }

    {:ok, summary}
  end

  @doc """
  Generates test inputs for a given property type.

  ## Parameters
    - property_type: The property type atom
    - opts: Generation options

  ## Returns
    - List of test input tuples
  """
  def generate_inputs(property_type, opts \\ %{}) do
    iterations = Map.get(opts, :iterations, @default_iterations)
    min_val = Map.get(opts, :min_value, @default_min_value)
    max_val = Map.get(opts, :max_value, @default_max_value)
    value_type = Map.get(opts, :value_type, :integer)

    # Set seed if provided for reproducibility
    case Map.get(opts, :seed) do
      nil -> :ok
      seed -> :rand.seed(:exsss, {seed, seed, seed})
    end

    schema = Map.get(@property_schemas, property_type, %{arity: 2})
    arity = Map.get(schema, :arity, 2)

    generate_input_list(iterations, arity, min_val, max_val, value_type)
  end

  # Private functions

  defp validate_property(nil, _property) do
    {:error, "Property type is required"}
  end

  defp validate_property(property_type, property) do
    case Map.get(@property_schemas, property_type) do
      nil ->
        {:error, "Unknown property type: #{property_type}"}

      schema ->
        missing_params =
          schema.required_params
          |> Enum.reject(&Map.has_key?(property, &1))

        if Enum.empty?(missing_params) do
          :ok
        else
          {:error, "Missing required parameters for #{property_type}: #{inspect(missing_params)}"}
        end
    end
  end

  defp run_property_test(gexpr, property_type, property, opts) do
    iterations = Map.get(opts, :iterations, @default_iterations)
    inputs = generate_inputs(property_type, opts)

    Logger.info("Running #{property_type} property test with #{iterations} iterations")

    start_time = System.monotonic_time(:millisecond)

    {test_results, counterexamples} =
      run_property_iterations(gexpr, property_type, property, inputs)

    end_time = System.monotonic_time(:millisecond)

    passed = Enum.all?(test_results, & &1.passed)
    passed_count = Enum.count(test_results, & &1.passed)
    failed_count = length(test_results) - passed_count

    result = %{
      property_type: property_type,
      passed: passed,
      iterations: length(test_results),
      passed_count: passed_count,
      failed_count: failed_count,
      counterexamples: Enum.take(counterexamples, 5),
      total_time_ms: end_time - start_time,
      config: %{
        iterations: iterations,
        min_value: Map.get(opts, :min_value, @default_min_value),
        max_value: Map.get(opts, :max_value, @default_max_value)
      }
    }

    {:ok, result}
  end

  defp run_property_iterations(gexpr, property_type, property, inputs) do
    results_and_counterexamples =
      Enum.map(inputs, fn input ->
        case check_property(gexpr, property_type, property, input) do
          {:ok, true} ->
            {%{passed: true, input: input}, nil}

          {:ok, false, details} ->
            counterexample = %{
              input: input,
              details: details
            }

            {%{passed: false, input: input}, counterexample}

          {:error, reason} ->
            counterexample = %{
              input: input,
              error: reason
            }

            {%{passed: false, input: input, error: reason}, counterexample}
        end
      end)

    results = Enum.map(results_and_counterexamples, &elem(&1, 0))

    counterexamples =
      results_and_counterexamples
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)

    {results, counterexamples}
  end

  defp check_property(gexpr, :commutativity, _property, {a, b}) do
    with {:ok, result_ab} <- apply_gexpr(gexpr, [a, b]),
         {:ok, result_ba} <- apply_gexpr(gexpr, [b, a]) do
      if result_ab == result_ba do
        {:ok, true}
      else
        {:ok, false,
         %{left: result_ab, right: result_ba, expected: "f(#{a}, #{b}) == f(#{b}, #{a})"}}
      end
    end
  end

  defp check_property(gexpr, :associativity, _property, {a, b, c}) do
    # f(f(a, b), c) == f(a, f(b, c))
    with {:ok, ab} <- apply_gexpr(gexpr, [a, b]),
         {:ok, left} <- apply_gexpr(gexpr, [ab, c]),
         {:ok, bc} <- apply_gexpr(gexpr, [b, c]),
         {:ok, right} <- apply_gexpr(gexpr, [a, bc]) do
      if left == right do
        {:ok, true}
      else
        {:ok, false,
         %{left: left, right: right, expected: "f(f(#{a}, #{b}), #{c}) == f(#{a}, f(#{b}, #{c}))"}}
      end
    end
  end

  defp check_property(gexpr, :identity, property, {a}) do
    identity = Map.fetch!(property, :identity_element)

    with {:ok, result} <- apply_gexpr(gexpr, [identity, a]) do
      if result == a do
        {:ok, true}
      else
        {:ok, false, %{result: result, expected: a, identity: identity}}
      end
    end
  end

  defp check_property(gexpr, :idempotence, _property, {a}) do
    with {:ok, result} <- apply_gexpr(gexpr, [a, a]) do
      if result == a do
        {:ok, true}
      else
        {:ok, false, %{result: result, expected: a, input: "f(#{a}, #{a})"}}
      end
    end
  end

  defp check_property(gexpr, :inverse, property, {a}) do
    identity = Map.fetch!(property, :identity_element)
    inverse_fn = Map.fetch!(property, :inverse_fn)

    # Calculate the inverse of a
    inverse_a = apply_inverse(inverse_fn, a)

    with {:ok, result} <- apply_gexpr(gexpr, [a, inverse_a]) do
      if result == identity do
        {:ok, true}
      else
        {:ok, false, %{result: result, expected: identity, input: a, inverse: inverse_a}}
      end
    end
  end

  defp check_property(gexpr, :monotonicity, _property, {a, b}) when a <= b do
    with {:ok, fa} <- apply_gexpr(gexpr, [a]),
         {:ok, fb} <- apply_gexpr(gexpr, [b]) do
      if fa <= fb do
        {:ok, true}
      else
        {:ok, false, %{a: a, b: b, fa: fa, fb: fb, expected: "f(#{a}) <= f(#{b})"}}
      end
    end
  end

  defp check_property(gexpr, :monotonicity, property, {a, b}) do
    # Swap to ensure a <= b
    check_property(gexpr, :monotonicity, property, {min(a, b), max(a, b)})
  end

  defp check_property(gexpr, :boundedness, property, {a}) do
    min_bound = Map.fetch!(property, :min_bound)
    max_bound = Map.fetch!(property, :max_bound)

    with {:ok, result} <- apply_gexpr(gexpr, [a]) do
      if result >= min_bound and result <= max_bound do
        {:ok, true}
      else
        {:ok, false, %{result: result, min_bound: min_bound, max_bound: max_bound, input: a}}
      end
    end
  end

  defp check_property(gexpr, :distributivity, property, {a, b, c}) do
    outer_fn = Map.fetch!(property, :outer_fn)

    # f(a, g(b, c)) == g(f(a, b), f(a, c))
    # where f is gexpr and g is outer_fn
    with {:ok, bc} <- apply_gexpr(outer_fn, [b, c]),
         {:ok, left} <- apply_gexpr(gexpr, [a, bc]),
         {:ok, ab} <- apply_gexpr(gexpr, [a, b]),
         {:ok, ac} <- apply_gexpr(gexpr, [a, c]),
         {:ok, right} <- apply_gexpr(outer_fn, [ab, ac]) do
      if left == right do
        {:ok, true}
      else
        {:ok, false,
         %{
           left: left,
           right: right,
           expected: "f(#{a}, g(#{b}, #{c})) == g(f(#{a}, #{b}), f(#{a}, #{c}))"
         }}
      end
    end
  end

  defp check_property(_gexpr, property_type, _property, _input) do
    {:error, "Unknown property type: #{property_type}"}
  end

  defp apply_gexpr(gexpr, args) do
    app_expr = %{
      "g" => "app",
      "v" => %{
        "fn" => gexpr,
        "args" => Enum.map(args, fn arg -> %{"g" => "lit", "v" => arg} end)
      }
    }

    Glisp.eval(app_expr)
  end

  defp apply_inverse(:negate, value), do: -value
  defp apply_inverse(:reciprocal, value) when value != 0, do: 1 / value
  defp apply_inverse(:reciprocal, _value), do: 0
  defp apply_inverse(fn_atom, value) when is_atom(fn_atom), do: apply(Kernel, fn_atom, [value])
  defp apply_inverse(fun, value) when is_function(fun, 1), do: fun.(value)

  defp generate_input_list(iterations, arity, min_val, max_val, value_type) do
    Enum.map(1..iterations, fn _ ->
      generate_input_tuple(arity, min_val, max_val, value_type)
    end)
  end

  defp generate_input_tuple(1, min_val, max_val, value_type) do
    {generate_value(min_val, max_val, value_type)}
  end

  defp generate_input_tuple(2, min_val, max_val, value_type) do
    {generate_value(min_val, max_val, value_type), generate_value(min_val, max_val, value_type)}
  end

  defp generate_input_tuple(3, min_val, max_val, value_type) do
    {generate_value(min_val, max_val, value_type), generate_value(min_val, max_val, value_type),
     generate_value(min_val, max_val, value_type)}
  end

  defp generate_input_tuple(n, min_val, max_val, value_type) when n > 3 do
    List.to_tuple(Enum.map(1..n, fn _ -> generate_value(min_val, max_val, value_type) end))
  end

  defp generate_value(min_val, max_val, :integer) do
    min_val + :rand.uniform(max_val - min_val + 1) - 1
  end

  defp generate_value(min_val, max_val, :float) do
    min_val + :rand.uniform() * (max_val - min_val)
  end
end
