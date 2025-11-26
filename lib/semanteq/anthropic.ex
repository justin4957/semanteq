defmodule Semanteq.Anthropic do
  @moduledoc """
  Anthropic Claude API client for G-Lisp code generation.

  Provides LLM integration with a specialized system prompt for
  generating valid G-expressions from natural language descriptions.
  """

  require Logger

  @api_version "2023-06-01"

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

  @doc """
  Returns configuration from application environment.
  """
  def config do
    Application.get_env(:semanteq, :anthropic)
  end

  @doc """
  Generates a G-expression from a natural language prompt.

  ## Parameters
    - prompt: Natural language description of the desired code
    - opts: Optional keyword list with :model, :max_tokens, :temperature

  ## Returns
    - `{:ok, gexpr}` on success (parsed JSON)
    - `{:error, reason}` on failure

  ## Examples

      iex> Semanteq.Anthropic.generate_gexpr("Create a function that doubles a number")
      {:ok, %{"g" => "lam", "v" => %{"params" => ["x"], "body" => ...}}}
  """
  def generate_gexpr(prompt, opts \\ []) do
    cfg = config()
    model = Keyword.get(opts, :model, cfg[:model])
    max_tokens = Keyword.get(opts, :max_tokens, cfg[:max_tokens] || 4096)
    temperature = Keyword.get(opts, :temperature, cfg[:temperature] || 0.7)

    request_body = %{
      model: model,
      max_tokens: max_tokens,
      temperature: temperature,
      system: @glisp_system_prompt,
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    case make_request(request_body) do
      {:ok, response} ->
        extract_gexpr(response)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Validates a G-expression and provides feedback.

  ## Parameters
    - gexpr: A G-expression to validate
    - context: Optional context about what the expression should do

  ## Returns
    - `{:ok, %{valid: boolean, feedback: string}}` with validation results
    - `{:error, reason}` on failure
  """
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

    request_body = %{
      model: cfg[:model],
      max_tokens: 1024,
      temperature: 0.3,
      system:
        "You are a G-Lisp code validator. Analyze G-expressions and report issues in JSON format.",
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    case make_request(request_body) do
      {:ok, response} ->
        parse_validation_response(response)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Refines a G-expression based on feedback or test failures.

  ## Parameters
    - gexpr: The original G-expression
    - feedback: Description of the issue or desired improvement
    - opts: Optional keyword list with :model, :max_tokens

  ## Returns
    - `{:ok, refined_gexpr}` on success
    - `{:error, reason}` on failure
  """
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
    model = Keyword.get(opts, :model, cfg[:model])
    max_tokens = Keyword.get(opts, :max_tokens, cfg[:max_tokens] || 4096)

    request_body = %{
      model: model,
      max_tokens: max_tokens,
      temperature: 0.5,
      system: @glisp_system_prompt,
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    case make_request(request_body) do
      {:ok, response} ->
        extract_gexpr(response)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Checks if the Anthropic API is accessible.

  ## Returns
    - `:ok` if API is accessible
    - `{:error, reason}` if not
  """
  def health_check do
    cfg = config()

    if cfg[:api_key] && cfg[:api_key] != "" do
      {:ok, %{status: "configured", model: cfg[:model]}}
    else
      {:error, :api_key_not_configured}
    end
  end

  # Private functions

  defp make_request(body) do
    cfg = config()
    api_key = cfg[:api_key]
    base_url = cfg[:base_url] || "https://api.anthropic.com/v1"

    if is_nil(api_key) or api_key == "" do
      {:error, :api_key_not_configured}
    else
      url = "#{base_url}/messages"

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ]

      Logger.debug("Making Anthropic API request to #{url}")

      case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
        {:ok, %{status: 200, body: response_body}} ->
          {:ok, response_body}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Anthropic API error: status=#{status}, body=#{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Anthropic API request failed: #{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp extract_gexpr(response) do
    case get_in(response, ["content"]) do
      nil ->
        {:error, :no_content_in_response}

      content_blocks when is_list(content_blocks) ->
        text =
          content_blocks
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", & &1["text"])

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
