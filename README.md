# Semanteq

LLM-based testing service for G-Lisp DSL creation and G-expression construction.

Semanteq combines Claude AI with G-Lisp to enable:
- Natural language to G-expression code generation
- Automated testing of generated expressions
- Semantic equivalence checking between expressions
- Iterative refinement based on test feedback

## Architecture

```
User Prompt
    |
    v
+------------------+
|    Semanteq      |
|  (Elixir :4001)  |
+------------------+
    |           |
    v           v
+----------+  +-------------------+
| Anthropic|  | G-Lisp (CLI)      |
| Claude   |  | clojure -M:repl   |
+----------+  | - eval            |
              | - test-generator  |
              | - equivalence     |
              +-------------------+
```

## Quick Start

### Prerequisites

- Elixir 1.14+
- Clojure CLI tools
- G-Lisp repository at `/Users/coolbeans/Development/dev/glisp-stuff/glisp`
- Anthropic API key

### Setup

1. Clone and install dependencies:
```bash
cd /Users/coolbeans/Development/dev/semanteq
mix deps.get
```

2. Set environment variable:
```bash
export ANTHROPIC_API_KEY="your-api-key"
```

3. Start the server:
```bash
mix run --no-halt
```

The server starts on port 4001 by default.

## API Endpoints

### POST /generate

Generate a G-expression from a natural language prompt.

```bash
curl -X POST http://localhost:4001/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Create a function that doubles a number"}'
```

Response:
```json
{
  "success": true,
  "data": {
    "prompt": "Create a function that doubles a number",
    "gexpr": {"g": "lam", "v": {"params": ["x"], "body": {...}}},
    "evaluation": {...},
    "tests": {"total": 0, "passed": 0, "skipped": true}
  }
}
```

### POST /eval

Evaluate a G-expression.

```bash
curl -X POST http://localhost:4001/eval \
  -H "Content-Type: application/json" \
  -d '{"gexpr": {"g": "app", "v": {"fn": {"g": "ref", "v": "+"}, "args": [{"g": "lit", "v": 1}, {"g": "lit", "v": 2}]}}}'
```

Response:
```json
{
  "success": true,
  "data": {"result": 3}
}
```

### POST /test

Test a G-expression against inputs or schema.

```bash
curl -X POST http://localhost:4001/test \
  -H "Content-Type: application/json" \
  -d '{
    "gexpr": {"g": "lam", "v": {"params": ["x"], "body": {"g": "app", "v": {"fn": {"g": "ref", "v": "*"}, "args": [{"g": "ref", "v": "x"}, {"g": "lit", "v": 2}]}}}},
    "test_inputs": [[1], [2], [5]]
  }'
```

### POST /equivalence

Check if two G-expressions are semantically equivalent.

```bash
curl -X POST http://localhost:4001/equivalence \
  -H "Content-Type: application/json" \
  -d '{
    "expr_a": {"g": "lam", "v": {"params": ["x"], "body": {"g": "app", "v": {"fn": {"g": "ref", "v": "*"}, "args": [{"g": "ref", "v": "x"}, {"g": "lit", "v": 2}]}}}},
    "expr_b": {"g": "lam", "v": {"params": ["n"], "body": {"g": "app", "v": {"fn": {"g": "ref", "v": "+"}, "args": [{"g": "ref", "v": "n"}, {"g": "ref", "v": "n"}]}}}},
    "inputs": [[1], [2], [5]]
  }'
```

### POST /validate

Validate a G-expression using LLM analysis.

```bash
curl -X POST http://localhost:4001/validate \
  -H "Content-Type: application/json" \
  -d '{
    "gexpr": {"g": "lam", "v": {"params": ["x"], "body": {...}}},
    "context": "This should double its input"
  }'
```

### POST /refine

Refine a G-expression based on feedback.

```bash
curl -X POST http://localhost:4001/refine \
  -H "Content-Type: application/json" \
  -d '{
    "gexpr": {"g": "lam", "v": {"params": ["x"], "body": {...}}},
    "feedback": "Handle negative numbers gracefully"
  }'
```

### GET /health

Health check endpoint.

```bash
curl http://localhost:4001/health
```

Response:
```json
{
  "status": "ok",
  "services": {
    "glisp": {"status": "ok"},
    "anthropic": {"status": "ok", "model": "claude-3-haiku-20240307"}
  }
}
```

## Elixir API

```elixir
# Generate and test a G-expression
{:ok, result} = Semanteq.generate("Create a function that adds two numbers")

# Generate with automatic refinement on failure
{:ok, result} = Semanteq.generate_with_refinement("Create a recursive factorial", %{max_retries: 3})

# Evaluate a G-expression
{:ok, 42} = Semanteq.eval(%{"g" => "lit", "v" => 42})

# Evaluate with trace
{:ok, %{"result" => result, "trace" => trace}} = Semanteq.eval_with_trace(gexpr)

# Check equivalence
{:ok, %{equivalent: true}} = Semanteq.equivalent?(expr_a, expr_b, %{inputs: [[1], [2]]})

# Validate using LLM
{:ok, %{valid: true, issues: []}} = Semanteq.validate(gexpr, "Should double a number")

# Refine based on feedback
{:ok, refined_gexpr} = Semanteq.refine(gexpr, "Handle edge cases")

# Check service health
%{glisp: %{status: "ok"}, anthropic: %{status: "ok"}} = Semanteq.health()
```

## Configuration

Configuration is in `config/config.exs`:

```elixir
# Anthropic API
config :semanteq, :anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-3-haiku-20240307",
  base_url: "https://api.anthropic.com/v1",
  max_tokens: 4096,
  temperature: 0.7

# G-Lisp CLI
config :semanteq, :glisp,
  project_dir: "/path/to/glisp",
  clojure_alias: "test",
  timeout_ms: 30_000

# HTTP server
config :semanteq, :http,
  port: 4001
```

## Testing

```bash
mix test
```

## Roadmap

### Phase 1: MVP (Current)
- [x] Project skeleton
- [x] Anthropic client with G-Lisp system prompt
- [x] G-Lisp CLI wrapper (eval, equivalence, test-generator)
- [x] Core generation pipeline
- [x] Simple HTTP API
- [x] README with examples

### Phase 2: Enhanced Testing
- [ ] Feedback loop (retry on validation failures)
- [ ] Batch testing support
- [ ] Property-based test generation
- [ ] Trace capture integration

### Phase 3: Multi-Provider
- [ ] Provider abstraction behaviour
- [ ] OpenAI adapter
- [ ] Local LLM (Ollama) adapter
- [ ] Provider comparison mode

### Phase 4: Persistence & Analytics
- [ ] Session management (ETS)
- [ ] Metrics collection
- [ ] Success rate tracking
- [ ] Graph DB for analytics

### Phase 5: Interactive Playground
- [ ] Phoenix LiveView UI
- [ ] Real-time streaming
- [ ] DSL creation wizard
- [ ] Pattern library integration

## License

MIT
