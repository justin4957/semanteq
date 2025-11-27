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

  ### GET /health
  Health check endpoint.
  """

  use Plug.Router

  alias Semanteq.{Generator, Glisp, Anthropic}

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

  # GET /health - Health check endpoint
  get "/health" do
    glisp_status = check_glisp_health()
    anthropic_status = check_anthropic_health()

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
        anthropic: anthropic_status
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

  defp check_anthropic_health do
    case Anthropic.health_check() do
      {:ok, info} -> Map.merge(%{status: "ok"}, info)
      {:error, reason} -> %{status: "error", error: format_error(reason)}
    end
  end
end
