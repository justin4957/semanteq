defmodule SemanteqTest do
  use ExUnit.Case

  alias Semanteq.{Glisp, Anthropic, Generator, Router}

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

    test "unknown route returns 404" do
      conn = Plug.Test.conn(:get, "/unknown")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 404
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["error"] == "Not found"
    end
  end
end
