defmodule Semanteq.Providers.OpenAI do
  @moduledoc """
  OpenAI GPT API provider for G-Lisp code generation.

  Implements the `Semanteq.Provider` behaviour for the OpenAI GPT API.
  This provider uses GPT models to generate, validate, and refine G-expressions
  from natural language descriptions.

  ## Configuration

  Configure in config.exs:

      config :semanteq, :openai,
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini",
        base_url: "https://api.openai.com/v1",
        max_tokens: 4096,
        temperature: 0.7

  ## Supported Models

  - `gpt-4o` - GPT-4o (most capable)
  - `gpt-4o-mini` - GPT-4o Mini (fast and cost-effective)
  - `gpt-4-turbo` - GPT-4 Turbo
  - `gpt-3.5-turbo` - GPT-3.5 Turbo (legacy)
  """

  @behaviour Semanteq.Provider

  require Logger

  @glisp_system_prompt """
  You are an expert G-Lisp code generator. G-Lisp is a Lisp implementation that operates on G-expressions.

  ## G-Expression Structure

  All code is represented as JSON objects with these fields:
  - `g` (genre): The operation type (lit, ref, app, lam, def, if, do, let, etc.)
  - `v` (value): The actual data/parameters
  - `m` (metadata): Optional type info, arity, and generation metadata

  ## Core Genres

  1. **lit** (literal): `{"g": "lit", "v": 42}` - A literal value
  2. **ref** (reference): `{"g": "ref", "v": "my-var"}` - Variable reference
  3. **app** (application): `{"g": "app", "v": {"fn": <fn-expr>, "args": [<arg-exprs>]}}` - Function application
  4. **lam** (lambda): `{"g": "lam", "v": {"params": ["x", "y"], "body": <body-expr>}}` - Lambda function
  5. **def** (definition): `{"g": "def", "v": {"name": "foo", "value": <expr>}}` - Definition
  6. **if** (conditional): `{"g": "if", "v": {"cond": <cond-expr>, "then": <then-expr>, "else": <else-expr>}}` - Conditional
  7. **let** (let binding): `{"g": "let", "v": {"bindings": [["x", <expr>]], "body": <body-expr>}}` - Let binding
  8. **do** (sequence): `{"g": "do", "v": [<expr1>, <expr2>, ...]}` - Sequential execution

  ## Examples

  ### Simple addition: (+ 1 2)
  ```json
  {
    "g": "app",
    "v": {
      "fn": {"g": "ref", "v": "+"},
      "args": [{"g": "lit", "v": 1}, {"g": "lit", "v": 2}]
    }
  }
  ```

  ### Lambda: (fn [x] (* x x))
  ```json
  {
    "g": "lam",
    "v": {
      "params": ["x"],
      "body": {
        "g": "app",
        "v": {
          "fn": {"g": "ref", "v": "*"},
          "args": [{"g": "ref", "v": "x"}, {"g": "ref", "v": "x"}]
        }
      }
    }
  }
  ```

  ## Available Built-in Functions

  Arithmetic: +, -, *, /, mod, abs, min, max, floor, ceil, round
  Comparison: =, <, >, <=, >=, not=
  Logic: and, or, not
  Collections: list, vector, map, first, rest, cons, conj, get, assoc, count, empty?, nth
  Strings: str, subs, upper-case, lower-case, trim, split, join
  Higher-order: map, filter, reduce, apply, comp, partial
  Type: type-of, number?, string?, list?, map?, fn?

  ## Response Format

  When generating G-expressions, respond with ONLY valid JSON. Do not include explanations, markdown formatting, or anything else.
  The response must be a single valid G-expression JSON object.
  """

  @default_model "gpt-4o-mini"
  @default_max_tokens 4096
  @default_temperature 0.7

  # ============================================================================
  # Provider Behaviour Implementation
  # ============================================================================

  @impl Semanteq.Provider
  def name, do: :openai

  @impl Semanteq.Provider
  def config do
    Application.get_env(:semanteq, :openai, [])
  end

  @impl Semanteq.Provider
  def generate_gexpr(prompt, opts \\ []) do
    cfg = config()
    model = Keyword.get(opts, :model, cfg[:model] || @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, cfg[:max_tokens] || @default_max_tokens)
    temperature = Keyword.get(opts, :temperature, cfg[:temperature] || @default_temperature)

    request_body = %{
      model: model,
      max_tokens: max_tokens,
      temperature: temperature,
      messages: [
        %{role: "system", content: @glisp_system_prompt},
        %{role: "user", content: prompt}
      ]
    }

    case make_request("/chat/completions", request_body) do
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

    ```json
    #{gexpr_json}
    ```

    #{if context != "", do: "Context: #{context}\n", else: ""}

    Respond with a JSON object containing:
    - "valid": boolean indicating if the expression is syntactically valid
    - "issues": array of any issues found (empty if valid)
    - "suggestions": array of improvement suggestions (optional)

    Respond with ONLY the JSON object, no additional text.
    """

    cfg = config()
    model = cfg[:model] || @default_model

    request_body = %{
      model: model,
      max_tokens: 1024,
      temperature: 0.3,
      messages: [
        %{
          role: "system",
          content:
            "You are a G-Lisp code validator. Analyze G-expressions and report issues in JSON format."
        },
        %{role: "user", content: prompt}
      ]
    }

    case make_request("/chat/completions", request_body) do
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
    Refine this G-expression based on the following feedback:

    Original G-expression:
    ```json
    #{gexpr_json}
    ```

    Feedback: #{feedback}

    Generate an improved G-expression that addresses the feedback.
    Respond with ONLY the JSON G-expression, no additional text.
    """

    cfg = config()
    model = Keyword.get(opts, :model, cfg[:model] || @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, cfg[:max_tokens] || @default_max_tokens)

    request_body = %{
      model: model,
      max_tokens: max_tokens,
      temperature: 0.5,
      messages: [
        %{role: "system", content: @glisp_system_prompt},
        %{role: "user", content: prompt}
      ]
    }

    case make_request("/chat/completions", request_body) do
      {:ok, response} ->
        extract_gexpr(response)

      {:error, _} = error ->
        error
    end
  end

  @impl Semanteq.Provider
  def health_check do
    cfg = config()

    if cfg[:api_key] && cfg[:api_key] != "" do
      {:ok, %{status: "configured", model: cfg[:model] || @default_model, provider: :openai}}
    else
      {:error, :api_key_not_configured}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp make_request(endpoint, body) do
    cfg = config()
    api_key = cfg[:api_key]
    base_url = cfg[:base_url] || "https://api.openai.com/v1"

    if is_nil(api_key) or api_key == "" do
      {:error, :api_key_not_configured}
    else
      url = "#{base_url}#{endpoint}"

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]

      Logger.debug("Making OpenAI API request to #{url}")

      case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
        {:ok, %{status: 200, body: response_body}} ->
          {:ok, response_body}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %{status: 400, body: body}} ->
          Logger.error("OpenAI API bad request: #{inspect(body)}")
          {:error, {:bad_request, body}}

        {:ok, %{status: status, body: body}} ->
          Logger.error("OpenAI API error: status=#{status}, body=#{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("OpenAI API request failed: #{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp extract_gexpr(response) do
    # OpenAI response format:
    # {"choices": [{"message": {"content": "..."}}]}
    case get_in(response, ["choices"]) do
      nil ->
        {:error, :no_choices_in_response}

      [] ->
        {:error, :empty_choices}

      [first_choice | _] ->
        case get_in(first_choice, ["message", "content"]) do
          nil ->
            {:error, :no_content_in_message}

          content when is_binary(content) ->
            parse_gexpr_from_text(content)

          _ ->
            {:error, :invalid_content_format}
        end

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

    case Jason.decode(text) do
      {:ok, gexpr} when is_map(gexpr) ->
        {:ok, gexpr}

      {:ok, _} ->
        {:error, :not_a_gexpr}

      {:error, reason} ->
        {:error, {:json_parse_error, reason, text}}
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
