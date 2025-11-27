defmodule Semanteq.Providers.Mock do
  @moduledoc """
  Mock LLM provider for testing.

  Implements the `Semanteq.Provider` behaviour with deterministic responses
  for testing purposes. This provider does not make any external API calls.

  ## Usage

  Set as the active provider for tests:

      Semanteq.Provider.set_active(:mock)

  Or use with_provider for isolated tests:

      Semanteq.Provider.with_provider(:mock, fn ->
        # Your test code here
      end)

  ## Configuration

  Configure in config.exs:

      config :semanteq, :mock_provider,
        default_response: %{"g" => "lit", "v" => 42},
        should_fail: false,
        latency_ms: 0
  """

  @behaviour Semanteq.Provider

  @impl Semanteq.Provider
  def name, do: :mock

  @impl Semanteq.Provider
  def config do
    Application.get_env(:semanteq, :mock_provider, [])
  end

  @impl Semanteq.Provider
  def generate_gexpr(prompt, opts \\ []) do
    cfg = config()
    should_fail = Keyword.get(opts, :should_fail, cfg[:should_fail] || false)
    latency_ms = Keyword.get(opts, :latency_ms, cfg[:latency_ms] || 0)

    if latency_ms > 0, do: Process.sleep(latency_ms)

    if should_fail do
      {:error, :mock_generation_failed}
    else
      # Generate a deterministic response based on the prompt
      gexpr = generate_mock_gexpr(prompt, opts)
      {:ok, gexpr}
    end
  end

  @impl Semanteq.Provider
  def validate_gexpr(gexpr, _context \\ "") do
    cfg = config()
    should_fail = cfg[:should_fail] || false

    if should_fail do
      {:error, :mock_validation_failed}
    else
      # Simple validation - check if it has the required structure
      valid = is_map(gexpr) and Map.has_key?(gexpr, "g")

      issues =
        cond do
          not is_map(gexpr) -> ["Not a map"]
          not Map.has_key?(gexpr, "g") -> ["Missing 'g' (genre) field"]
          true -> []
        end

      {:ok,
       %{
         valid: valid,
         issues: issues,
         suggestions: []
       }}
    end
  end

  @impl Semanteq.Provider
  def refine_gexpr(gexpr, feedback, opts \\ []) do
    cfg = config()
    should_fail = Keyword.get(opts, :should_fail, cfg[:should_fail] || false)

    if should_fail do
      {:error, :mock_refinement_failed}
    else
      # Return a slightly modified version of the original
      refined =
        gexpr
        |> Map.put("m", %{
          "refined" => true,
          "feedback" => String.slice(feedback, 0, 50)
        })

      {:ok, refined}
    end
  end

  @impl Semanteq.Provider
  def health_check do
    cfg = config()
    should_fail = cfg[:should_fail] || false

    if should_fail do
      {:error, :mock_unhealthy}
    else
      {:ok, %{status: "ok", provider: :mock, mode: "testing"}}
    end
  end

  # ============================================================================
  # Mock Response Generation
  # ============================================================================

  defp generate_mock_gexpr(prompt, opts) do
    # Check for custom response in opts
    case Keyword.get(opts, :mock_response) do
      nil -> generate_default_mock_gexpr(prompt)
      response -> response
    end
  end

  defp generate_default_mock_gexpr(prompt) do
    prompt_lower = String.downcase(prompt)

    cond do
      String.contains?(prompt_lower, "double") ->
        # Lambda that doubles a number
        %{
          "g" => "lam",
          "v" => %{
            "params" => ["x"],
            "body" => %{
              "g" => "app",
              "v" => %{
                "fn" => %{"g" => "ref", "v" => "*"},
                "args" => [
                  %{"g" => "ref", "v" => "x"},
                  %{"g" => "lit", "v" => 2}
                ]
              }
            }
          }
        }

      String.contains?(prompt_lower, "add") ->
        # Lambda that adds two numbers
        %{
          "g" => "lam",
          "v" => %{
            "params" => ["a", "b"],
            "body" => %{
              "g" => "app",
              "v" => %{
                "fn" => %{"g" => "ref", "v" => "+"},
                "args" => [
                  %{"g" => "ref", "v" => "a"},
                  %{"g" => "ref", "v" => "b"}
                ]
              }
            }
          }
        }

      String.contains?(prompt_lower, "factorial") ->
        # Simple factorial using recursion pattern
        %{
          "g" => "lam",
          "v" => %{
            "params" => ["n"],
            "body" => %{
              "g" => "if",
              "v" => %{
                "cond" => %{
                  "g" => "app",
                  "v" => %{
                    "fn" => %{"g" => "ref", "v" => "<="},
                    "args" => [
                      %{"g" => "ref", "v" => "n"},
                      %{"g" => "lit", "v" => 1}
                    ]
                  }
                },
                "then" => %{"g" => "lit", "v" => 1},
                "else" => %{
                  "g" => "app",
                  "v" => %{
                    "fn" => %{"g" => "ref", "v" => "*"},
                    "args" => [
                      %{"g" => "ref", "v" => "n"},
                      %{"g" => "lit", "v" => 1}
                    ]
                  }
                }
              }
            }
          }
        }

      String.contains?(prompt_lower, "square") ->
        # Lambda that squares a number
        %{
          "g" => "lam",
          "v" => %{
            "params" => ["x"],
            "body" => %{
              "g" => "app",
              "v" => %{
                "fn" => %{"g" => "ref", "v" => "*"},
                "args" => [
                  %{"g" => "ref", "v" => "x"},
                  %{"g" => "ref", "v" => "x"}
                ]
              }
            }
          }
        }

      String.contains?(prompt_lower, "identity") ->
        # Identity function
        %{
          "g" => "lam",
          "v" => %{
            "params" => ["x"],
            "body" => %{"g" => "ref", "v" => "x"}
          }
        }

      true ->
        # Default: return a simple literal
        %{
          "g" => "lit",
          "v" => 42,
          "m" => %{"generated_from" => String.slice(prompt, 0, 30)}
        }
    end
  end
end
