defmodule Semanteq.Providers.Ollama do
  @moduledoc """
  Ollama local LLM provider for G-Lisp code generation.

  Implements the `Semanteq.Provider` behaviour for local LLM inference via Ollama.
  This provider enables running models like Llama, Mistral, CodeLlama, and others
  locally without cloud API costs.

  ## Configuration

  Configure in config.exs:

      config :semanteq, :ollama,
        base_url: "http://localhost:11434",
        model: "llama3.2",
        timeout_ms: 120_000,
        num_ctx: 4096,
        temperature: 0.7

  ## Supported Models

  Any model available in your local Ollama installation:
  - `llama3.2` - Meta Llama 3.2 (recommended for code)
  - `llama3.1` - Meta Llama 3.1
  - `mistral` - Mistral 7B
  - `codellama` - Code Llama (optimized for code)
  - `deepseek-coder` - DeepSeek Coder
  - `phi3` - Microsoft Phi-3

  ## Prerequisites

  Ollama must be installed and running locally:

      # Install Ollama (macOS)
      brew install ollama

      # Start Ollama server
      ollama serve

      # Pull a model
      ollama pull llama3.2
  """

  @behaviour Semanteq.Provider

  require Logger

  # Optimized system prompt for smaller local models
  # More concise than cloud provider prompts to fit in smaller context windows
  @glisp_system_prompt """
  You are a G-Lisp code generator. Generate ONLY valid JSON G-expressions.

  G-Expression Structure:
  - `g` (genre): Operation type (lit, ref, app, lam, def, if, do, let)
  - `v` (value): Data/parameters
  - `m` (metadata): Optional

  Core Genres:
  - lit: {"g": "lit", "v": 42} - Literal value
  - ref: {"g": "ref", "v": "x"} - Variable reference
  - app: {"g": "app", "v": {"fn": <fn>, "args": [<args>]}} - Function call
  - lam: {"g": "lam", "v": {"params": ["x"], "body": <expr>}} - Lambda
  - def: {"g": "def", "v": {"name": "foo", "value": <expr>}} - Definition
  - if: {"g": "if", "v": {"cond": <c>, "then": <t>, "else": <e>}} - Conditional
  - let: {"g": "let", "v": {"bindings": [["x", <expr>]], "body": <expr>}} - Let binding
  - do: {"g": "do", "v": [<expr1>, <expr2>]} - Sequence

  Example - (+ 1 2):
  {"g": "app", "v": {"fn": {"g": "ref", "v": "+"}, "args": [{"g": "lit", "v": 1}, {"g": "lit", "v": 2}]}}

  Built-ins: +, -, *, /, =, <, >, and, or, not, list, first, rest, map, filter, reduce

  RESPOND WITH ONLY JSON. NO EXPLANATIONS.
  """

  @default_model "llama3.2"
  @default_base_url "http://localhost:11434"
  @default_timeout_ms 120_000
  @default_num_ctx 4096
  @default_temperature 0.7

  # ============================================================================
  # Provider Behaviour Implementation
  # ============================================================================

  @impl Semanteq.Provider
  def name, do: :ollama

  @impl Semanteq.Provider
  def config do
    Application.get_env(:semanteq, :ollama, [])
  end

  @impl Semanteq.Provider
  def generate_gexpr(prompt, opts \\ []) do
    cfg = config()
    model = Keyword.get(opts, :model, cfg[:model] || @default_model)
    temperature = Keyword.get(opts, :temperature, cfg[:temperature] || @default_temperature)
    num_ctx = Keyword.get(opts, :num_ctx, cfg[:num_ctx] || @default_num_ctx)

    request_body = %{
      model: model,
      prompt: "#{@glisp_system_prompt}\n\nTask: #{prompt}",
      stream: false,
      options: %{
        temperature: temperature,
        num_ctx: num_ctx
      }
    }

    case make_request("/api/generate", request_body, opts) do
      {:ok, response} ->
        extract_gexpr(response)

      {:error, _} = error ->
        error
    end
  end

  @impl Semanteq.Provider
  def validate_gexpr(gexpr, context \\ "") do
    gexpr_json = Jason.encode!(gexpr)

    prompt = """
    Analyze this G-expression for correctness:

    #{gexpr_json}

    #{if context != "", do: "Context: #{context}", else: ""}

    Respond with JSON only:
    {"valid": true/false, "issues": ["issue1", ...], "suggestions": ["suggestion1", ...]}
    """

    cfg = config()
    model = cfg[:model] || @default_model

    request_body = %{
      model: model,
      prompt: prompt,
      stream: false,
      options: %{
        temperature: 0.3,
        num_ctx: cfg[:num_ctx] || @default_num_ctx
      }
    }

    case make_request("/api/generate", request_body) do
      {:ok, response} ->
        parse_validation_response(response)

      {:error, _} = error ->
        error
    end
  end

  @impl Semanteq.Provider
  def refine_gexpr(gexpr, feedback, opts \\ []) do
    gexpr_json = Jason.encode!(gexpr)

    prompt = """
    #{@glisp_system_prompt}

    Original G-expression:
    #{gexpr_json}

    Feedback: #{feedback}

    Generate improved G-expression. RESPOND WITH ONLY JSON.
    """

    cfg = config()
    model = Keyword.get(opts, :model, cfg[:model] || @default_model)
    num_ctx = Keyword.get(opts, :num_ctx, cfg[:num_ctx] || @default_num_ctx)

    request_body = %{
      model: model,
      prompt: prompt,
      stream: false,
      options: %{
        temperature: 0.5,
        num_ctx: num_ctx
      }
    }

    case make_request("/api/generate", request_body, opts) do
      {:ok, response} ->
        extract_gexpr(response)

      {:error, _} = error ->
        error
    end
  end

  @impl Semanteq.Provider
  def health_check do
    cfg = config()
    base_url = cfg[:base_url] || @default_base_url

    case check_ollama_status(base_url) do
      {:ok, _} ->
        case list_available_models(base_url) do
          {:ok, models} ->
            configured_model = cfg[:model] || @default_model
            model_available = Enum.any?(models, &String.starts_with?(&1, configured_model))

            {:ok,
             %{
               status: "connected",
               provider: :ollama,
               base_url: base_url,
               model: configured_model,
               model_available: model_available,
               available_models: models
             }}

          {:error, reason} ->
            {:error, {:cannot_list_models, reason}}
        end

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  # ============================================================================
  # Streaming Support
  # ============================================================================

  @doc """
  Generates a G-expression with streaming response.

  Returns a stream of partial responses that can be processed incrementally.
  Useful for providing real-time feedback during generation.

  ## Options
    - `:on_token` - Callback function called with each token (optional)
    - All standard generate_gexpr options

  ## Returns
    - `{:ok, gexpr}` with the final parsed G-expression
    - `{:error, reason}` on failure
  """
  def generate_gexpr_stream(prompt, opts \\ []) do
    cfg = config()
    model = Keyword.get(opts, :model, cfg[:model] || @default_model)
    temperature = Keyword.get(opts, :temperature, cfg[:temperature] || @default_temperature)
    num_ctx = Keyword.get(opts, :num_ctx, cfg[:num_ctx] || @default_num_ctx)
    on_token = Keyword.get(opts, :on_token, fn _token -> :ok end)

    request_body = %{
      model: model,
      prompt: "#{@glisp_system_prompt}\n\nTask: #{prompt}",
      stream: true,
      options: %{
        temperature: temperature,
        num_ctx: num_ctx
      }
    }

    case make_streaming_request("/api/generate", request_body, on_token, opts) do
      {:ok, full_response} ->
        parse_gexpr_from_text(full_response)

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Model Management
  # ============================================================================

  @doc """
  Lists all models available in the local Ollama installation.

  ## Returns
    - `{:ok, [model_names]}` on success
    - `{:error, reason}` on failure
  """
  def list_models do
    cfg = config()
    base_url = cfg[:base_url] || @default_base_url
    list_available_models(base_url)
  end

  @doc """
  Checks if a specific model is available locally.

  ## Returns
    - `true` if model is available
    - `false` otherwise
  """
  def model_available?(model_name) do
    case list_models() do
      {:ok, models} ->
        Enum.any?(models, &String.starts_with?(&1, model_name))

      {:error, _} ->
        false
    end
  end

  @doc """
  Gets information about a specific model.

  ## Returns
    - `{:ok, model_info}` with model details
    - `{:error, reason}` on failure
  """
  def model_info(model_name) do
    cfg = config()
    base_url = cfg[:base_url] || @default_base_url
    url = "#{base_url}/api/show"

    case Req.post(url, json: %{name: model_name}, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :model_not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp make_request(endpoint, body, opts \\ []) do
    cfg = config()
    base_url = cfg[:base_url] || @default_base_url
    timeout_ms = Keyword.get(opts, :timeout_ms, cfg[:timeout_ms] || @default_timeout_ms)

    url = "#{base_url}#{endpoint}"

    Logger.debug("Making Ollama API request to #{url}")

    case Req.post(url, json: body, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: 404}} ->
        {:error, :model_not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        Logger.warning("Ollama server not running at #{base_url}")
        {:error, :ollama_not_running}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.warning("Ollama request timed out after #{timeout_ms}ms")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Ollama API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp make_streaming_request(endpoint, body, on_token, opts) do
    cfg = config()
    base_url = cfg[:base_url] || @default_base_url
    timeout_ms = Keyword.get(opts, :timeout_ms, cfg[:timeout_ms] || @default_timeout_ms)

    url = "#{base_url}#{endpoint}"

    Logger.debug("Making streaming Ollama API request to #{url}")

    # Accumulate the full response
    accumulated_response = ""

    into_fun = fn {:data, data}, acc ->
      case Jason.decode(data) do
        {:ok, %{"response" => token, "done" => false}} ->
          on_token.(token)
          {:cont, acc <> token}

        {:ok, %{"response" => token, "done" => true}} ->
          on_token.(token)
          {:cont, acc <> token}

        {:ok, %{"done" => true}} ->
          {:cont, acc}

        _ ->
          {:cont, acc}
      end
    end

    case Req.post(url,
           json: body,
           receive_timeout: timeout_ms,
           into: into_fun,
           raw: true
         ) do
      {:ok, %{status: 200, body: final_acc}} when is_binary(final_acc) ->
        {:ok, final_acc}

      {:ok, %{status: 200}} ->
        {:ok, accumulated_response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp check_ollama_status(base_url) do
    url = "#{base_url}/api/tags"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200}} ->
        {:ok, :connected}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_available_models(base_url) do
    url = "#{base_url}/api/tags"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        model_names = Enum.map(models, & &1["name"])
        {:ok, model_names}

      {:ok, %{status: 200, body: _}} ->
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp extract_gexpr(response) do
    case Map.get(response, "response") do
      nil ->
        {:error, :no_response_in_body}

      text when is_binary(text) ->
        parse_gexpr_from_text(text)

      _ ->
        {:error, :invalid_response_format}
    end
  end

  defp parse_gexpr_from_text(text) do
    text = String.trim(text)

    # Remove markdown code blocks if present
    text =
      text
      |> String.replace(~r/^```json\s*\n?/i, "")
      |> String.replace(~r/^```\s*\n?/i, "")
      |> String.replace(~r/\n?```\s*$/i, "")
      |> String.trim()

    # Try to extract JSON from the response if there's extra text
    text = extract_json_from_text(text)

    case Jason.decode(text) do
      {:ok, gexpr} when is_map(gexpr) ->
        {:ok, gexpr}

      {:ok, _} ->
        {:error, :not_a_gexpr}

      {:error, reason} ->
        {:error, {:json_parse_error, reason, text}}
    end
  end

  # Local models sometimes include extra text before/after JSON
  # Try to extract the JSON object from the response
  defp extract_json_from_text(text) do
    # First try the text as-is
    if String.starts_with?(text, "{") and String.ends_with?(text, "}") do
      text
    else
      # Try to find JSON object in the text
      case Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/s, text) do
        [json] -> json
        nil -> text
      end
    end
  end

  defp parse_validation_response(response) do
    case extract_gexpr(response) do
      {:ok, result} when is_map(result) ->
        {:ok,
         %{
           valid: Map.get(result, "valid", false),
           issues: Map.get(result, "issues", []),
           suggestions: Map.get(result, "suggestions", [])
         }}

      {:error, _} = error ->
        error
    end
  end
end
