defmodule SemanteqTest do
  use ExUnit.Case

  alias Semanteq.{Glisp, Anthropic, Generator, Router, PropertyTester, Tracer}

  describe "Semanteq.Glisp" do
    test "project_dir returns configured path" do
      assert Glisp.project_dir() != nil
    end

    test "clojure_alias returns test by default" do
      assert Glisp.clojure_alias() == "test"
    end

    test "timeout_ms returns configured or default value" do
      timeout = Glisp.timeout_ms()
      assert is_integer(timeout)
      assert timeout > 0
    end
  end

  describe "Semanteq.Anthropic" do
    test "config returns configuration" do
      config = Anthropic.config()
      assert is_list(config) or is_nil(config)
    end

    test "health_check returns error when API key not configured" do
      # In test env, API key is "test-api-key" which is invalid
      # but health_check only checks if it's configured
      result = Anthropic.health_check()
      assert {:ok, %{status: "configured"}} = result
    end
  end

  describe "Semanteq.Generator" do
    test "run_tests returns skipped when no schema or inputs" do
      gexpr = %{"g" => "lit", "v" => 42}
      {:ok, result} = Generator.run_tests(gexpr, %{})
      assert result.skipped == true
    end

    test "default_retry_config returns expected defaults" do
      config = Generator.default_retry_config()
      assert config.max_retries == 3
      assert config.retry_on == [:generate, :evaluate, :test]
      assert config.backoff_ms == 100
      assert config.exponential_backoff == true
    end

    test "default_batch_config returns expected defaults" do
      config = Generator.default_batch_config()
      assert config.parallelism == 5
      assert config.stop_on_error == false
      assert config.with_retry == false
    end
  end

  describe "Semanteq.PropertyTester" do
    test "available_properties returns property schemas" do
      properties = PropertyTester.available_properties()
      assert is_map(properties)
      assert Map.has_key?(properties, :commutativity)
      assert Map.has_key?(properties, :associativity)
      assert Map.has_key?(properties, :identity)
      assert Map.has_key?(properties, :idempotence)
      assert Map.has_key?(properties, :monotonicity)
      assert Map.has_key?(properties, :boundedness)
    end

    test "default_config returns expected defaults" do
      config = PropertyTester.default_config()
      assert config.iterations == 100
      assert config.min_value == -1000
      assert config.max_value == 1000
      assert config.seed == nil
      assert config.value_type == :integer
    end

    test "generate_inputs returns correct number of inputs" do
      inputs = PropertyTester.generate_inputs(:commutativity, %{iterations: 10})
      assert length(inputs) == 10
      # Commutativity requires 2 inputs
      assert Enum.all?(inputs, fn tuple -> tuple_size(tuple) == 2 end)
    end

    test "generate_inputs respects seed for reproducibility" do
      opts = %{iterations: 5, seed: 42}
      inputs1 = PropertyTester.generate_inputs(:commutativity, opts)
      inputs2 = PropertyTester.generate_inputs(:commutativity, opts)
      assert inputs1 == inputs2
    end

    test "test_property returns error for unknown property type" do
      gexpr = %{"g" => "lit", "v" => 42}
      property = %{type: :unknown_property}
      {:error, reason} = PropertyTester.test_property(gexpr, property)
      assert reason =~ "Unknown property type"
    end

    test "test_property returns error when required params missing" do
      gexpr = %{"g" => "lit", "v" => 42}
      property = %{type: :identity}
      {:error, reason} = PropertyTester.test_property(gexpr, property)
      assert reason =~ "Missing required parameters"
    end
  end

  describe "Semanteq.Tracer" do
    test "trace_levels returns available levels" do
      levels = Tracer.trace_levels()
      assert is_map(levels)
      assert Map.has_key?(levels, :minimal)
      assert Map.has_key?(levels, :standard)
      assert Map.has_key?(levels, :verbose)
    end

    test "default_config returns expected defaults" do
      config = Tracer.default_config()
      assert config.level == :standard
      assert config.include_source == true
      assert config.include_timestamps == true
      assert config.max_depth == 100
    end

    test "compare_traces returns comparison result" do
      trace_a = %{level: :standard, status: :success, steps: [], duration_ms: 10}
      trace_b = %{level: :standard, status: :success, steps: [], duration_ms: 15}

      {:ok, result} = Tracer.compare_traces(trace_a, trace_b)
      assert Map.has_key?(result, :equivalent)
      assert Map.has_key?(result, :differences)
      assert Map.has_key?(result, :summary)
    end

    test "compare_traces detects level mismatch" do
      trace_a = %{level: :minimal, status: :success, steps: []}
      trace_b = %{level: :verbose, status: :success, steps: []}

      {:ok, result} = Tracer.compare_traces(trace_a, trace_b)
      assert result.equivalent == false
      assert Enum.any?(result.differences, &(&1.type == :level_mismatch))
    end

    test "analyze_trace returns analysis" do
      trace = %{
        level: :standard,
        status: :success,
        steps: [%{type: :eval, depth: 0}, %{type: :app, depth: 1}],
        step_count: 2,
        duration_ms: 50
      }

      {:ok, analysis} = Tracer.analyze_trace(trace)
      assert analysis.total_steps == 2
      assert is_map(analysis.step_type_distribution)
      assert analysis.duration_ms == 50
    end

    test "format_trace returns JSON string" do
      trace = %{level: :standard, status: :success}
      json = Tracer.format_trace(trace, %{format: :json})
      assert is_binary(json)
      {:ok, _} = Jason.decode(json)
    end
  end

  describe "Semanteq public API" do
    test "health returns service status" do
      health = Semanteq.health()
      assert Map.has_key?(health, :glisp)
      assert Map.has_key?(health, :anthropic)
    end
  end

  describe "Semanteq.Router" do
    setup do
      # Create a test connection
      {:ok, conn: Plug.Test.conn(:get, "/")}
    end

    test "GET /health returns 200", %{conn: _conn} do
      conn = Plug.Test.conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] in ["ok", "degraded"]
    end

    test "POST /generate without prompt returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/generate", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "prompt"
    end

    test "POST /eval without gexpr returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/eval", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "gexpr"
    end

    test "POST /test without gexpr returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/test", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
    end

    test "POST /equivalence without expressions returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/equivalence", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
    end

    test "POST /validate without gexpr returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/validate", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
    end

    test "POST /refine without gexpr or feedback returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/refine", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
    end

    test "POST /generate-with-retry without prompt returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/generate-with-retry", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "prompt"
    end

    test "GET /retry-config returns default configuration" do
      conn = Plug.Test.conn(:get, "/retry-config")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert body["data"]["max_retries"] == 3
      assert body["data"]["retry_on"] == ["generate", "evaluate", "test"]
      assert body["data"]["backoff_ms"] == 100
      assert body["data"]["exponential_backoff"] == true
    end

    test "POST /batch without prompts returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/batch", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "prompts"
    end

    test "POST /batch with non-array prompts returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/batch", Jason.encode!(%{"prompts" => "not an array"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "must be an array"
    end

    test "POST /batch with invalid prompt item returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/batch", Jason.encode!(%{"prompts" => [%{"no_prompt" => "here"}]}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "prompt"
    end

    test "GET /batch-config returns default configuration" do
      conn = Plug.Test.conn(:get, "/batch-config")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert body["data"]["parallelism"] == 5
      assert body["data"]["stop_on_error"] == false
      assert body["data"]["with_retry"] == false
    end

    test "POST /property-test without gexpr returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/property-test", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "gexpr"
    end

    test "POST /property-test without property returns 400" do
      conn =
        :post
        |> Plug.Test.conn(
          "/property-test",
          Jason.encode!(%{"gexpr" => %{"g" => "lit", "v" => 1}})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "property"
    end

    test "POST /property-tests without gexpr returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/property-tests", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "gexpr"
    end

    test "POST /property-tests without properties returns 400" do
      conn =
        :post
        |> Plug.Test.conn(
          "/property-tests",
          Jason.encode!(%{"gexpr" => %{"g" => "lit", "v" => 1}})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "properties"
    end

    test "POST /property-tests with non-array properties returns 400" do
      conn =
        :post
        |> Plug.Test.conn(
          "/property-tests",
          Jason.encode!(%{
            "gexpr" => %{"g" => "lit", "v" => 1},
            "properties" => "not an array"
          })
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "must be an array"
    end

    test "GET /property-config returns default configuration" do
      conn = Plug.Test.conn(:get, "/property-config")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert body["data"]["iterations"] == 100
      assert body["data"]["min_value"] == -1000
      assert body["data"]["max_value"] == 1000
    end

    test "GET /properties returns available property types" do
      conn = Plug.Test.conn(:get, "/properties")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert is_list(body["data"])
      # Should have at least commutativity and associativity
      types = Enum.map(body["data"], & &1["type"])
      assert "commutativity" in types
      assert "associativity" in types
    end

    test "POST /trace without gexpr returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/trace", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "gexpr"
    end

    test "POST /trace/compare without trace_a returns 400" do
      conn =
        :post
        |> Plug.Test.conn(
          "/trace/compare",
          Jason.encode!(%{"trace_b" => %{"level" => "standard"}})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "trace_a"
    end

    test "POST /trace/compare without trace_b returns 400" do
      conn =
        :post
        |> Plug.Test.conn(
          "/trace/compare",
          Jason.encode!(%{"trace_a" => %{"level" => "standard"}})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "trace_b"
    end

    test "POST /trace/compare with both traces returns 200" do
      conn =
        :post
        |> Plug.Test.conn(
          "/trace/compare",
          Jason.encode!(%{
            "trace_a" => %{"level" => "standard", "steps" => []},
            "trace_b" => %{"level" => "standard", "steps" => []}
          })
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert Map.has_key?(body["data"], "equivalent")
    end

    test "POST /trace/analyze without trace returns 400" do
      conn =
        :post
        |> Plug.Test.conn("/trace/analyze", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "trace"
    end

    test "POST /trace/analyze with trace returns 200" do
      conn =
        :post
        |> Plug.Test.conn(
          "/trace/analyze",
          Jason.encode!(%{
            "trace" => %{"level" => "standard", "steps" => [], "duration_ms" => 10}
          })
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert Map.has_key?(body["data"], "total_steps")
    end

    test "GET /trace-config returns default configuration" do
      conn = Plug.Test.conn(:get, "/trace-config")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert body["data"]["level"] == "standard"
      assert body["data"]["include_source"] == true
      assert body["data"]["max_depth"] == 100
    end

    test "GET /trace-levels returns available levels" do
      conn = Plug.Test.conn(:get, "/trace-levels")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert Map.has_key?(body["data"], "minimal")
      assert Map.has_key?(body["data"], "standard")
      assert Map.has_key?(body["data"], "verbose")
    end

    test "unknown route returns 404" do
      conn = Plug.Test.conn(:get, "/unknown")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 404
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"] == "Not found"
    end
  end
end
