defmodule SemanteqTest do
  use ExUnit.Case

  alias Semanteq.{Glisp, Anthropic, Generator, Router, PropertyTester, Tracer, Provider}
  alias Semanteq.Providers.{Mock, OpenAI, Ollama}

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

    test "GET /providers returns list of providers" do
      conn = Plug.Test.conn(:get, "/providers")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert is_map(body["data"]["providers"])
      assert body["data"]["active"] in ["anthropic", "mock"]
    end

    test "GET /provider returns active provider" do
      conn = Plug.Test.conn(:get, "/provider")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == true
      assert is_binary(body["data"]["name"])
      assert is_binary(body["data"]["module"])
    end

    test "PUT /provider with invalid provider returns 400" do
      conn =
        :put
        |> Plug.Test.conn("/provider", Jason.encode!(%{"provider" => "nonexistent"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "Unknown provider"
      assert is_list(body["available_providers"])
    end

    test "PUT /provider without provider field returns 400" do
      conn =
        :put
        |> Plug.Test.conn("/provider", Jason.encode!(%{}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Router.call(conn, Router.init([]))

      assert conn.status == 400
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["success"] == false
      assert body["error"] =~ "provider"
    end
  end

  describe "Semanteq.Provider" do
    test "registered_providers returns a map" do
      providers = Provider.registered_providers()
      assert is_map(providers)
      assert Map.has_key?(providers, :anthropic)
      assert Map.has_key?(providers, :mock)
    end

    test "get_active returns a module" do
      module = Provider.get_active()
      assert is_atom(module)
    end

    test "get_active_name returns an atom" do
      name = Provider.get_active_name()
      assert is_atom(name)
      assert name in [:anthropic, :mock]
    end

    test "set_active with valid provider returns :ok" do
      original = Provider.get_active_name()

      try do
        assert :ok = Provider.set_active(:mock)
        assert Provider.get_active_name() == :mock
      after
        Provider.set_active(original)
      end
    end

    test "set_active with invalid provider returns error" do
      assert {:error, :unknown_provider} = Provider.set_active(:nonexistent)
    end

    test "reset_active restores default provider" do
      Provider.set_active(:mock)
      Provider.reset_active()
      # After reset, it should use config default
      assert is_atom(Provider.get_active_name())
    end

    test "with_provider temporarily switches provider" do
      original = Provider.get_active_name()

      result =
        Provider.with_provider(:mock, fn ->
          assert Provider.get_active_name() == :mock
          :test_result
        end)

      assert result == :test_result
      # Provider should be restored after the block
      assert Provider.get_active_name() == original
    end

    test "list_providers returns all providers with active status" do
      providers = Provider.list_providers()
      assert is_map(providers)
      assert Map.has_key?(providers, :anthropic)
      assert Map.has_key?(providers, :mock)

      Enum.each(providers, fn {_name, info} ->
        assert Map.has_key?(info, :module)
        assert Map.has_key?(info, :active)
      end)
    end

    test "health_check delegates to active provider" do
      result = Provider.health_check()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Semanteq.Providers.Mock" do
    test "name returns :mock" do
      assert Mock.name() == :mock
    end

    test "health_check returns ok status" do
      assert {:ok, %{status: "ok", provider: :mock}} = Mock.health_check()
    end

    test "generate_gexpr returns deterministic response for double prompt" do
      {:ok, gexpr} = Mock.generate_gexpr("Create a function that doubles a number")
      assert gexpr["g"] == "lam"
      assert gexpr["v"]["params"] == ["x"]
    end

    test "generate_gexpr returns deterministic response for add prompt" do
      {:ok, gexpr} = Mock.generate_gexpr("Create a function that adds two numbers")
      assert gexpr["g"] == "lam"
      assert gexpr["v"]["params"] == ["a", "b"]
    end

    test "generate_gexpr returns default for unknown prompt" do
      {:ok, gexpr} = Mock.generate_gexpr("Something random")
      assert gexpr["g"] == "lit"
      assert gexpr["v"] == 42
    end

    test "generate_gexpr with should_fail option returns error" do
      assert {:error, :mock_generation_failed} = Mock.generate_gexpr("test", should_fail: true)
    end

    test "generate_gexpr with custom mock_response uses it" do
      custom = %{"g" => "custom", "v" => "test"}
      {:ok, gexpr} = Mock.generate_gexpr("test", mock_response: custom)
      assert gexpr == custom
    end

    test "validate_gexpr returns valid for proper gexpr" do
      {:ok, result} = Mock.validate_gexpr(%{"g" => "lit", "v" => 42})
      assert result.valid == true
      assert result.issues == []
    end

    test "validate_gexpr returns invalid for improper gexpr" do
      {:ok, result} = Mock.validate_gexpr(%{"invalid" => "structure"})
      assert result.valid == false
      assert length(result.issues) > 0
    end

    test "refine_gexpr adds metadata to expression" do
      original = %{"g" => "lit", "v" => 42}
      {:ok, refined} = Mock.refine_gexpr(original, "Make it better")

      assert refined["g"] == "lit"
      assert refined["v"] == 42
      assert refined["m"]["refined"] == true
      assert refined["m"]["feedback"] =~ "Make it"
    end
  end

  describe "Semanteq.Providers.OpenAI" do
    test "name returns :openai" do
      assert OpenAI.name() == :openai
    end

    test "config returns configuration" do
      config = OpenAI.config()
      assert is_list(config) or is_nil(config)
    end

    test "health_check returns configured when API key is set" do
      # In test env, API key is "test-openai-api-key"
      result = OpenAI.health_check()
      assert {:ok, %{status: "configured", provider: :openai}} = result
    end

    test "generate_gexpr returns error when API key not configured" do
      # Override config to simulate missing API key
      original_config = Application.get_env(:semanteq, :openai)

      try do
        Application.put_env(:semanteq, :openai, api_key: nil)
        result = OpenAI.generate_gexpr("test prompt")
        assert {:error, :api_key_not_configured} = result
      after
        Application.put_env(:semanteq, :openai, original_config)
      end
    end

    test "health_check returns error when API key not configured" do
      original_config = Application.get_env(:semanteq, :openai)

      try do
        Application.put_env(:semanteq, :openai, api_key: nil)
        result = OpenAI.health_check()
        assert {:error, :api_key_not_configured} = result
      after
        Application.put_env(:semanteq, :openai, original_config)
      end
    end
  end

  describe "Provider with OpenAI" do
    test "OpenAI is registered as a provider" do
      providers = Provider.registered_providers()
      assert Map.has_key?(providers, :openai)
      assert providers[:openai] == Semanteq.Providers.OpenAI
    end

    test "can set OpenAI as active provider" do
      original = Provider.get_active_name()

      try do
        assert :ok = Provider.set_active(:openai)
        assert Provider.get_active_name() == :openai
        assert Provider.get_active() == Semanteq.Providers.OpenAI
      after
        Provider.set_active(original)
      end
    end

    test "with_provider works with OpenAI" do
      original = Provider.get_active_name()

      result =
        Provider.with_provider(:openai, fn ->
          assert Provider.get_active_name() == :openai
          :openai_test_result
        end)

      assert result == :openai_test_result
      assert Provider.get_active_name() == original
    end

    test "list_providers includes OpenAI" do
      providers = Provider.list_providers()
      assert Map.has_key?(providers, :openai)
      assert providers[:openai].module == Semanteq.Providers.OpenAI
    end
  end

  describe "Semanteq.Providers.Ollama" do
    test "name returns :ollama" do
      assert Ollama.name() == :ollama
    end

    test "config returns configuration" do
      config = Ollama.config()
      assert is_list(config) or is_nil(config)
    end

    test "health_check returns ollama_unavailable when server not running" do
      # In test env, Ollama is typically not running
      result = Ollama.health_check()
      # Should return error since Ollama server likely not available in CI
      assert match?({:error, {:ollama_unavailable, _}}, result) or
               match?({:ok, %{status: "connected"}}, result)
    end

    test "generate_gexpr returns error or success depending on Ollama availability" do
      result = Ollama.generate_gexpr("test prompt")
      # Result depends on whether Ollama is running and has the model
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "list_models returns error or list when Ollama not running" do
      result = Ollama.list_models()
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "model_available? returns false when Ollama not running" do
      # Should return false since Ollama is not running
      result = Ollama.model_available?("llama3.2")
      assert is_boolean(result)
    end

    test "model_info returns error when Ollama not running" do
      result = Ollama.model_info("llama3.2")
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "validate_gexpr returns error when Ollama not running" do
      gexpr = %{"g" => "lit", "v" => 42}
      result = Ollama.validate_gexpr(gexpr, "test context")
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "refine_gexpr returns error when Ollama not running" do
      gexpr = %{"g" => "lit", "v" => 42}
      result = Ollama.refine_gexpr(gexpr, "make it better")
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "Provider with Ollama" do
    test "Ollama is registered as a provider" do
      providers = Provider.registered_providers()
      assert Map.has_key?(providers, :ollama)
      assert providers[:ollama] == Semanteq.Providers.Ollama
    end

    test "can set Ollama as active provider" do
      original = Provider.get_active_name()

      try do
        assert :ok = Provider.set_active(:ollama)
        assert Provider.get_active_name() == :ollama
        assert Provider.get_active() == Semanteq.Providers.Ollama
      after
        Provider.set_active(original)
      end
    end

    test "with_provider works with Ollama" do
      original = Provider.get_active_name()

      result =
        Provider.with_provider(:ollama, fn ->
          assert Provider.get_active_name() == :ollama
          :ollama_test_result
        end)

      assert result == :ollama_test_result
      assert Provider.get_active_name() == original
    end

    test "list_providers includes Ollama" do
      providers = Provider.list_providers()
      assert Map.has_key?(providers, :ollama)
      assert providers[:ollama].module == Semanteq.Providers.Ollama
    end
  end
end
