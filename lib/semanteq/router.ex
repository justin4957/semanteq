defmodule Semanteq.Router do
  @moduledoc """
  HTTP API router for Semanteq.

  Provides REST endpoints for G-Lisp code generation and testing.

  ## Endpoints

  ### POST /generate
  Generate G-expression from prompt.

  Request body:
  ```json
  {"prompt": "Create a function that doubles a number", "options": {"with_trace": false}}
  ```

  ### POST /eval
  Evaluate a G-expression.

  Request body:
  ```json
  {"gexpr": {"g": "lit", "v": 42}, "with_trace": false}
  ```

  ### POST /test
  Test a G-expression against schema or inputs.

  Request body:
  ```json
  {"gexpr": {...}, "schema": {"input_types": ["number"]}, "test_inputs": [[1], [2]]}
  ```

  ### POST /equivalence
  Check equivalence of two G-expressions.

  Request body:
  ```json
  {"expr_a": {...}, "expr_b": {...}, "inputs": [[1], [2]]}
  ```

  ### POST /validate
  Validate a G-expression using LLM.

  Request body:
  ```json
  {"gexpr": {...}, "context": "Should double a number"}
  ```

  ### POST /refine
  Refine a G-expression based on feedback.

  Request body:
  ```json
  {"gexpr": {...}, "feedback": "Handle negative numbers"}
  ```

  ### POST /generate-with-retry
  Generate G-expression with automatic retry on failure.

  Request body:
  ```json
  {
    "prompt": "Create a factorial function",
    "max_retries": 3,
    "retry_on": ["generate", "evaluate", "test"],
    "backoff_ms": 100
  }
  ```

  ### GET /retry-config
  Get default retry configuration.

  ### POST /batch
  Process multiple prompts in batch with parallel execution.

  Request body:
  ```json
  {
    "prompts": [
      "Create a function that doubles a number",
      {"prompt": "Create a factorial function", "test_inputs": [[5]]}
    ],
    "parallelism": 5,
    "stop_on_error": false,
    "with_retry": false
  }
  ```

  ### GET /batch-config
  Get default batch configuration.

  ### POST /property-test
  Test a G-expression against a mathematical property.

  Request body:
  ```json
  {
    "gexpr": {...},
    "property": {"type": "commutativity"},
    "iterations": 100,
    "min_value": -1000,
    "max_value": 1000
  }
  ```

  ### POST /property-tests
  Test a G-expression against multiple properties.

  Request body:
  ```json
  {
    "gexpr": {...},
    "properties": [
      {"type": "commutativity"},
      {"type": "associativity"}
    ],
    "iterations": 50
  }
  ```

  ### GET /property-config
  Get default property testing configuration.

  ### GET /properties
  Get list of available property types.

  ### POST /trace
  Evaluate a G-expression with detailed trace capture.

  Request body:
  ```json
  {
    "gexpr": {...},
    "level": "standard",
    "include_source": true,
    "include_timestamps": true
  }
  ```

  ### POST /trace/compare
  Compare two execution traces.

  Request body:
  ```json
  {
    "trace_a": {...},
    "trace_b": {...},
    "ignore_timing": true,
    "compare_steps": true
  }
  ```

  ### POST /trace/analyze
  Analyze a trace for insights and statistics.

  Request body:
  ```json
  {
    "trace": {...},
    "include_hotspots": true
  }
  ```

  ### GET /trace-config
  Get default trace configuration.

  ### GET /trace-levels
  Get available trace levels and descriptions.

  ### GET /providers
  List all registered providers.

  Response:
  ```json
  {
    "success": true,
    "data": {
      "providers": {"anthropic": {"module": "...", "active": true}, ...},
      "active": "anthropic"
    }
  }
  ```

  ### GET /provider
  Get the currently active provider.

  ### PUT /provider
  Set the active provider for this request context.

  Request body:
  ```json
  {"provider": "mock"}
  ```

  ### GET /health
  Health check endpoint.
  """

  use Plug.Router

  alias Semanteq.{Generator, Glisp, Anthropic, PropertyTester, Tracer, Provider}

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # POST /generate - Generate G-expression from prompt
  post "/generate" do
    case conn.body_params do
      %{"prompt" => prompt} = params ->
        opts = parse_options(params)

        case Generator.generate_and_test(prompt, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: prompt"})
    end
  end

  # POST /eval - Evaluate a G-expression
  post "/eval" do
    case conn.body_params do
      %{"gexpr" => gexpr} = params ->
        eval_fn =
          if Map.get(params, "with_trace", false) do
            &Glisp.eval_with_trace/1
          else
            &Glisp.eval/1
          end

        case eval_fn.(gexpr) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: %{result: result}})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: gexpr"})
    end
  end

  # POST /test - Test a G-expression against schema or inputs
  post "/test" do
    case conn.body_params do
      %{"gexpr" => gexpr} = params ->
        opts = parse_options(params)

        case Generator.run_tests(gexpr, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, _step, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: gexpr"})
    end
  end

  # POST /equivalence - Check equivalence of two G-expressions
  post "/equivalence" do
    case conn.body_params do
      %{"expr_a" => expr_a, "expr_b" => expr_b} = params ->
        opts = %{inputs: Map.get(params, "inputs", [])}

        case Generator.test_equivalence(expr_a, expr_b, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{
          success: false,
          error: "Missing required fields: expr_a, expr_b"
        })
    end
  end

  # POST /validate - Validate a G-expression using LLM
  post "/validate" do
    case conn.body_params do
      %{"gexpr" => gexpr} = params ->
        context = Map.get(params, "context", "")

        case Anthropic.validate_gexpr(gexpr, context) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: gexpr"})
    end
  end

  # POST /refine - Refine a G-expression based on feedback
  post "/refine" do
    case conn.body_params do
      %{"gexpr" => gexpr, "feedback" => feedback} ->
        case Anthropic.refine_gexpr(gexpr, feedback) do
          {:ok, refined} ->
            send_json(conn, 200, %{success: true, data: %{gexpr: refined}})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{
          success: false,
          error: "Missing required fields: gexpr, feedback"
        })
    end
  end

  # POST /generate-with-retry - Generate with automatic retry on failure
  post "/generate-with-retry" do
    case conn.body_params do
      %{"prompt" => prompt} = params ->
        opts = parse_retry_options(params)

        case Generator.generate_with_retry(prompt, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: prompt"})
    end
  end

  # GET /retry-config - Get default retry configuration
  get "/retry-config" do
    config = Generator.default_retry_config()

    send_json(conn, 200, %{
      success: true,
      data: %{
        max_retries: config.max_retries,
        retry_on: Enum.map(config.retry_on, &Atom.to_string/1),
        backoff_ms: config.backoff_ms,
        exponential_backoff: config.exponential_backoff
      }
    })
  end

  # POST /batch - Process multiple prompts in batch
  post "/batch" do
    case conn.body_params do
      %{"prompts" => prompts} when is_list(prompts) ->
        opts = parse_batch_options(conn.body_params)

        try do
          {:ok, result} = Generator.batch_generate_from_json(prompts, opts)
          send_json(conn, 200, %{success: true, data: result})
        rescue
          ArgumentError ->
            send_json(conn, 400, %{
              success: false,
              error: "Invalid batch item: each item must have a 'prompt' field"
            })
        end

      %{"prompts" => _} ->
        send_json(conn, 400, %{success: false, error: "Field 'prompts' must be an array"})

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: prompts"})
    end
  end

  # GET /batch-config - Get default batch configuration
  get "/batch-config" do
    config = Generator.default_batch_config()

    send_json(conn, 200, %{
      success: true,
      data: %{
        parallelism: config.parallelism,
        stop_on_error: config.stop_on_error,
        with_retry: config.with_retry
      }
    })
  end

  # POST /property-test - Test a G-expression against a property
  post "/property-test" do
    case conn.body_params do
      %{"gexpr" => gexpr, "property" => property} = params ->
        opts = parse_property_options(params)
        parsed_property = parse_property(property)

        case PropertyTester.test_property(gexpr, parsed_property, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      %{"gexpr" => _gexpr} ->
        send_json(conn, 400, %{success: false, error: "Missing required field: property"})

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required fields: gexpr, property"})
    end
  end

  # POST /property-tests - Test a G-expression against multiple properties
  post "/property-tests" do
    case conn.body_params do
      %{"gexpr" => gexpr, "properties" => properties} = params when is_list(properties) ->
        opts = parse_property_options(params)
        parsed_properties = Enum.map(properties, &parse_property/1)

        {:ok, result} = PropertyTester.test_properties(gexpr, parsed_properties, opts)
        send_json(conn, 200, %{success: true, data: result})

      %{"gexpr" => _gexpr, "properties" => _} ->
        send_json(conn, 400, %{success: false, error: "Field 'properties' must be an array"})

      %{"gexpr" => _gexpr} ->
        send_json(conn, 400, %{success: false, error: "Missing required field: properties"})

      _ ->
        send_json(conn, 400, %{
          success: false,
          error: "Missing required fields: gexpr, properties"
        })
    end
  end

  # GET /property-config - Get default property testing configuration
  get "/property-config" do
    config = PropertyTester.default_config()

    send_json(conn, 200, %{
      success: true,
      data: config
    })
  end

  # GET /properties - Get list of available property types
  get "/properties" do
    properties = PropertyTester.available_properties()

    formatted_properties =
      Enum.map(properties, fn {type, schema} ->
        %{
          type: type,
          description: schema.description,
          required_params: schema.required_params,
          arity: schema.arity
        }
      end)

    send_json(conn, 200, %{
      success: true,
      data: formatted_properties
    })
  end

  # POST /trace - Evaluate with detailed trace capture
  post "/trace" do
    case conn.body_params do
      %{"gexpr" => gexpr} = params ->
        opts = parse_trace_options(params)

        case Tracer.eval_with_trace(gexpr, opts) do
          {:ok, result} ->
            send_json(conn, 200, %{success: true, data: result})

          {:error, %{reason: reason, trace: trace}} ->
            send_json(conn, 422, %{
              success: false,
              error: format_error(reason),
              trace: trace
            })

          {:error, reason} ->
            send_json(conn, 422, %{success: false, error: format_error(reason)})
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: gexpr"})
    end
  end

  # POST /trace/compare - Compare two execution traces
  post "/trace/compare" do
    case conn.body_params do
      %{"trace_a" => trace_a, "trace_b" => trace_b} = params ->
        opts = parse_trace_compare_options(params)
        # Convert string keys to atoms for traces
        trace_a_normalized = normalize_trace_keys(trace_a)
        trace_b_normalized = normalize_trace_keys(trace_b)

        {:ok, result} = Tracer.compare_traces(trace_a_normalized, trace_b_normalized, opts)
        send_json(conn, 200, %{success: true, data: result})

      %{"trace_a" => _} ->
        send_json(conn, 400, %{success: false, error: "Missing required field: trace_b"})

      %{"trace_b" => _} ->
        send_json(conn, 400, %{success: false, error: "Missing required field: trace_a"})

      _ ->
        send_json(conn, 400, %{
          success: false,
          error: "Missing required fields: trace_a, trace_b"
        })
    end
  end

  # POST /trace/analyze - Analyze a trace for insights
  post "/trace/analyze" do
    case conn.body_params do
      %{"trace" => trace} = params ->
        opts = parse_trace_analyze_options(params)
        trace_normalized = normalize_trace_keys(trace)

        {:ok, result} = Tracer.analyze_trace(trace_normalized, opts)
        send_json(conn, 200, %{success: true, data: result})

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: trace"})
    end
  end

  # GET /trace-config - Get default trace configuration
  get "/trace-config" do
    config = Tracer.default_config()

    send_json(conn, 200, %{
      success: true,
      data: config
    })
  end

  # GET /trace-levels - Get available trace levels
  get "/trace-levels" do
    levels = Tracer.trace_levels()

    send_json(conn, 200, %{
      success: true,
      data: levels
    })
  end

  # GET /providers - List all registered providers
  get "/providers" do
    providers = Provider.list_providers()

    formatted_providers =
      Enum.map(providers, fn {name, info} ->
        {Atom.to_string(name),
         %{
           module: inspect(info.module),
           active: info.active
         }}
      end)
      |> Map.new()

    send_json(conn, 200, %{
      success: true,
      data: %{
        providers: formatted_providers,
        active: Atom.to_string(Provider.get_active_name())
      }
    })
  end

  # GET /provider - Get the currently active provider
  get "/provider" do
    provider_name = Provider.get_active_name()

    send_json(conn, 200, %{
      success: true,
      data: %{
        name: Atom.to_string(provider_name),
        module: inspect(Provider.get_active())
      }
    })
  end

  # PUT /provider - Set the active provider for this process
  put "/provider" do
    case conn.body_params do
      %{"provider" => provider_name} when is_binary(provider_name) ->
        provider_atom =
          try do
            String.to_existing_atom(provider_name)
          rescue
            ArgumentError -> String.to_atom(provider_name)
          end

        case Provider.set_active(provider_atom) do
          :ok ->
            send_json(conn, 200, %{
              success: true,
              data: %{
                active: provider_name,
                message: "Provider switched to #{provider_name}"
              }
            })

          {:error, :unknown_provider} ->
            available =
              Provider.registered_providers() |> Map.keys() |> Enum.map(&Atom.to_string/1)

            send_json(conn, 400, %{
              success: false,
              error: "Unknown provider: #{provider_name}",
              available_providers: available
            })
        end

      _ ->
        send_json(conn, 400, %{success: false, error: "Missing required field: provider"})
    end
  end

  # GET /health - Health check endpoint
  get "/health" do
    glisp_status = check_glisp_health()
    provider_status = check_provider_health()

    overall_status =
      if glisp_status[:status] == "ok" do
        "ok"
      else
        "degraded"
      end

    send_json(conn, 200, %{
      status: overall_status,
      services: %{
        glisp: glisp_status,
        provider: provider_status
      }
    })
  end

  # Catch-all for unmatched routes
  match _ do
    send_json(conn, 404, %{success: false, error: "Not found"})
  end

  # Private helpers

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp parse_options(params) do
    opts = %{}

    opts =
      if Map.has_key?(params, "schema") do
        Map.put(opts, :schema, params["schema"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "test_inputs") do
        Map.put(opts, :test_inputs, params["test_inputs"])
      else
        opts
      end

    if Map.get(params, "with_trace", false) do
      Map.put(opts, :with_trace, true)
    else
      opts
    end
  end

  defp parse_retry_options(params) do
    opts = parse_options(params)

    opts =
      if Map.has_key?(params, "max_retries") do
        Map.put(opts, :max_retries, params["max_retries"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "retry_on") do
        retry_on =
          params["retry_on"]
          |> Enum.map(&String.to_existing_atom/1)

        Map.put(opts, :retry_on, retry_on)
      else
        opts
      end

    opts =
      if Map.has_key?(params, "backoff_ms") do
        Map.put(opts, :backoff_ms, params["backoff_ms"])
      else
        opts
      end

    if Map.has_key?(params, "exponential_backoff") do
      Map.put(opts, :exponential_backoff, params["exponential_backoff"])
    else
      opts
    end
  end

  defp parse_batch_options(params) do
    opts = %{}

    opts =
      if Map.has_key?(params, "parallelism") do
        Map.put(opts, :parallelism, params["parallelism"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "stop_on_error") do
        Map.put(opts, :stop_on_error, params["stop_on_error"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "with_retry") do
        Map.put(opts, :with_retry, params["with_retry"])
      else
        opts
      end

    # Include retry options if with_retry is enabled
    if Map.get(params, "with_retry", false) do
      parse_retry_options(params)
      |> Map.merge(opts)
    else
      opts
    end
  end

  defp parse_property_options(params) do
    opts = %{}

    opts =
      if Map.has_key?(params, "iterations") do
        Map.put(opts, :iterations, params["iterations"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "min_value") do
        Map.put(opts, :min_value, params["min_value"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "max_value") do
        Map.put(opts, :max_value, params["max_value"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "seed") do
        Map.put(opts, :seed, params["seed"])
      else
        opts
      end

    if Map.has_key?(params, "value_type") do
      value_type = String.to_existing_atom(params["value_type"])
      Map.put(opts, :value_type, value_type)
    else
      opts
    end
  end

  defp parse_property(property) when is_map(property) do
    # Convert string keys to atoms for known property fields
    type =
      case Map.get(property, "type") || Map.get(property, :type) do
        nil -> nil
        type when is_binary(type) -> String.to_existing_atom(type)
        type when is_atom(type) -> type
      end

    base = %{type: type}

    # Parse optional parameters based on property type
    base
    |> maybe_add_param(property, "identity_element", :identity_element)
    |> maybe_add_param(property, "inverse_fn", :inverse_fn, &parse_inverse_fn/1)
    |> maybe_add_param(property, "outer_fn", :outer_fn)
    |> maybe_add_param(property, "min_bound", :min_bound)
    |> maybe_add_param(property, "max_bound", :max_bound)
    |> maybe_add_param(property, "description", :description)
  end

  defp maybe_add_param(map, source, string_key, atom_key, transformer \\ &Function.identity/1) do
    value = Map.get(source, string_key) || Map.get(source, atom_key)

    if value do
      Map.put(map, atom_key, transformer.(value))
    else
      map
    end
  end

  defp parse_inverse_fn("negate"), do: :negate
  defp parse_inverse_fn("reciprocal"), do: :reciprocal
  defp parse_inverse_fn(fn_name) when is_binary(fn_name), do: String.to_existing_atom(fn_name)
  defp parse_inverse_fn(fn_atom) when is_atom(fn_atom), do: fn_atom

  defp parse_trace_options(params) do
    opts = %{}

    opts =
      if Map.has_key?(params, "level") do
        level =
          case params["level"] do
            level when is_binary(level) -> String.to_existing_atom(level)
            level when is_atom(level) -> level
            _ -> :standard
          end

        Map.put(opts, :level, level)
      else
        opts
      end

    opts =
      if Map.has_key?(params, "include_source") do
        Map.put(opts, :include_source, params["include_source"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "include_timestamps") do
        Map.put(opts, :include_timestamps, params["include_timestamps"])
      else
        opts
      end

    if Map.has_key?(params, "max_depth") do
      Map.put(opts, :max_depth, params["max_depth"])
    else
      opts
    end
  end

  defp parse_trace_compare_options(params) do
    opts = %{}

    opts =
      if Map.has_key?(params, "ignore_timing") do
        Map.put(opts, :ignore_timing, params["ignore_timing"])
      else
        opts
      end

    if Map.has_key?(params, "compare_steps") do
      Map.put(opts, :compare_steps, params["compare_steps"])
    else
      opts
    end
  end

  defp parse_trace_analyze_options(params) do
    if Map.has_key?(params, "include_hotspots") do
      %{include_hotspots: params["include_hotspots"]}
    else
      %{}
    end
  end

  defp normalize_trace_keys(trace) when is_map(trace) do
    trace
    |> Enum.map(fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> String.to_atom(k)
          end

        {atom_key, normalize_trace_value(v)}

      {k, v} ->
        {k, normalize_trace_value(v)}
    end)
    |> Map.new()
  end

  defp normalize_trace_keys(other), do: other

  defp normalize_trace_value(value) when is_map(value), do: normalize_trace_keys(value)

  defp normalize_trace_value(value) when is_list(value),
    do: Enum.map(value, &normalize_trace_value/1)

  defp normalize_trace_value(value), do: value

  defp format_error(%{step: step, reason: reason}) do
    "Failed at #{step}: #{inspect(reason)}"
  end

  defp format_error(reason) when is_atom(reason) do
    Atom.to_string(reason)
  end

  defp format_error(reason) when is_binary(reason) do
    reason
  end

  defp format_error(reason) do
    inspect(reason)
  end

  defp check_glisp_health do
    case Glisp.health_check() do
      {:ok, _} -> %{status: "ok"}
      {:error, reason} -> %{status: "error", error: format_error(reason)}
    end
  end

  defp check_provider_health do
    case Provider.health_check() do
      {:ok, info} ->
        Map.merge(
          %{status: "ok", active_provider: Atom.to_string(Provider.get_active_name())},
          info
        )

      {:error, reason} ->
        %{
          status: "error",
          active_provider: Atom.to_string(Provider.get_active_name()),
          error: format_error(reason)
        }
    end
  end
end
