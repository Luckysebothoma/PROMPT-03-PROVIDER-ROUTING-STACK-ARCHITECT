# Day 3 — Provider Routing & Execution Stack

Stack name: `ai-gateway-3-of-10-provider-routing`

## Architecture

```
Client
  |
  v
Stack 1 - Chat Foundation
  |
  v
Stack 2 - Provider Registry (:4402)
  |
  v
Stack 3 - Provider Router (:4405 -> container :8080)
  |
  +----> Groq (implemented)
  |
  +----> Gemini (implemented when configured)\n  |\n  +----> Ollama (local, OpenAI-compatible API)
```

Stack 3 resolves `provider`, `model`, routing strategy, and request
configuration, then executes the request against an implemented provider.

Two contracts sit on top of this execution boundary: `POST /v1/chat` is the
user-facing single-message contract, and `POST /v1/execute` is the
provider-neutral execution contract consumed by upstream orchestration such
as Stack 5, which selects the worker/provider/model and hands Stack 3 the
execution request. Stack 5 owns *why* a model was selected; Stack 3 owns
*how* it is actually executed.

## Directory structure

```
PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT/
  src/
    server.js              Express app entrypoint
    routes/meta.js          /health /ready /dependencies /providers /help /metrics
    routes/chat.js           POST /v1/chat
    routes/execute.js        POST /v1/execute (Stack 5 execution contract)
    lib/config.js            env-driven configuration
    lib/logger.js            structured JSON logging
    lib/metrics.js           Prometheus metrics
    lib/db.js                Postgres pool + request_log persistence
    lib/redisClient.js       Redis client + routing state
    lib/router.js            provider resolution strategy
    lib/executionService.js  shared routing+execution+persistence for /v1/chat and /v1/execute
    providers/registry.js    provider registry (implemented/enabled/configured)
    providers/groq.js        Groq execution implementation
  db/init/001_init.sql       request_log table
  tests/run-tests.js          infrastructure + real execution test suite
  tests/e2e-execute.sh        real end-to-end /v1/execute curl test
  redis/redis.conf
  prometheus/prometheus.yml
  grafana/provisioning/...
  Dockerfile
  docker-compose.yml
  .env.example
```

## Environment variables

| Variable | Purpose |
|---|---|
| PORT | API listen port inside container (8080) |
| POSTGRES_HOST/PORT/DB/USER/PASSWORD | Postgres connection |
| REDIS_HOST/PORT | Redis connection |
| GROQ_API_KEY | Groq API key (required for Groq execution) |
| GROQ_DEFAULT_MODEL | Default Groq model (e.g. llama-3.1-8b-instant) |
| GROQ_ENABLED | Enable/disable Groq provider |
| GEMINI_API_KEY / GEMINI_DEFAULT_MODEL / GEMINI_ENABLED | Registry-only, not implemented |
| GRAFANA_ADMIN_USER/PASSWORD | Grafana login |

Copy `.env.example` to `.env` and fill in secrets. `.env` is never committed.

## Installation & Deployment

```bash
chmod +x deploy-ai-gateway-3-of-10.sh
./deploy-ai-gateway-3-of-10.sh init
```

This generates the project (if not already present), builds Docker images,
starts the stack, and runs health/readiness verification.

Other commands:

```bash
./deploy-ai-gateway-3-of-10.sh build
./deploy-ai-gateway-3-of-10.sh up
./deploy-ai-gateway-3-of-10.sh down
./deploy-ai-gateway-3-of-10.sh restart
./deploy-ai-gateway-3-of-10.sh ps
./deploy-ai-gateway-3-of-10.sh logs
./deploy-ai-gateway-3-of-10.sh health
./deploy-ai-gateway-3-of-10.sh test
./deploy-ai-gateway-3-of-10.sh clean
```

## API endpoints

- `GET /health` — liveness
- `GET /ready` — readiness (Postgres + Redis reachability)
- `GET /dependencies` — dependency connectivity detail
- `GET /providers` — provider registry state (no secrets exposed)
- `GET /help` — endpoint + routing strategy summary
- `GET /metrics` — Prometheus metrics
- `POST /v1/chat` — route + execute a single-message chat request (user-facing contract)
- `POST /v1/execute` — provider-neutral execution contract for upstream orchestration such as Stack 5 (structured `messages[]`)

## Provider routing

Strategy (deterministic, no load balancing yet):

1. Explicit `provider` in request body
2. Explicit `model` (used once a provider is resolved)
3. Automatic selection (`provider: "auto"` or omitted) — deterministic
   Redis-backed round-robin across implemented+enabled+configured providers
4. Fallback: first healthy implemented provider (used if Redis is unavailable)

### Request

```json
{
  "message": "Hello",
  "provider": "groq",
  "model": "llama-3.1-8b-instant",
  "temperature": 0.3
}
```

### Success response

```json
{
  "success": true,
  "provider": "groq",
  "model": "llama-3.1-8b-instant",
  "message": "Hello",
  "response": "Hello! How can I help?",
  "usage": {},
  "request_id": "..."
}
```

### Error response

```json
{
  "success": false,
  "error": { "code": "PROVIDER_UNAVAILABLE", "message": "No available provider could execute this request" },
  "request_id": "..."
}
```

## Execution API (/v1/execute)

`POST /v1/execute` is the provider-neutral execution contract consumed by
upstream orchestration such as Stack 5. Stack 5 already decided which
worker/provider/model to use; Stack 3 validates the request, resolves the
provider through the same routing layer as `/v1/chat`, executes it, and
returns a normalized result. It is **not** an alias of `/v1/chat` — it
requires structured `messages[]` instead of a single `message` string, and
Stack 5 never needs to know provider-specific request/response formats.

### Request

```json
{
  "provider": "groq",
  "model": "openai/gpt-oss-120b",
  "messages": [
    { "role": "system", "content": "You are a helpful assistant." },
    { "role": "user", "content": "Hello" }
  ],
  "temperature": 0.7,
  "max_tokens": 1000
}
```

`provider` and `model` are optional; omitting `provider` (or sending
`"auto"`) uses the same deterministic routing strategy as `/v1/chat`.

### Success response

```json
{
  "success": true,
  "provider": "groq",
  "model": "openai/gpt-oss-120b",
  "response": "...",
  "usage": {},
  "request_id": "..."
}
```

### Error response

Same provider-neutral error contract as `/v1/chat`:

```json
{
  "success": false,
  "error": { "code": "MODEL_NOT_FOUND", "message": "Groq does not recognize model \\"...\\"" },
  "request_id": "..."
}
```

Error codes: `INVALID_REQUEST`, `PROVIDER_NOT_FOUND`, `PROVIDER_NOT_IMPLEMENTED`,
`PROVIDER_NOT_CONFIGURED`, `PROVIDER_DISABLED`, `PROVIDER_UNAVAILABLE`,
`MODEL_NOT_FOUND`, and provider-execution codes such as `PROVIDER_AUTH_FAILED`,
`PROVIDER_RATE_LIMITED`, `UPSTREAM_TIMEOUT`, `PROVIDER_EXECUTION_FAILED`.

`/v1/chat` and `/v1/execute` share the same routing, provider execution,
response normalization, metrics, and `request_log` persistence via
`src/lib/executionService.js` — no execution logic is duplicated between them.

## Groq configuration

Set in `.env`:

```
GROQ_API_KEY=your_key_here
GROQ_DEFAULT_MODEL=llama-3.1-8b-instant
GROQ_ENABLED=true
```

If `GROQ_API_KEY` is missing, Groq shows as `configured: false` in
`GET /providers`, and any request routed to it fails gracefully with
`PROVIDER_NOT_CONFIGURED`.

## Ollama (local provider)

Ollama is available as an optional Day 3 execution provider. It uses Ollama's
OpenAI-compatible `/v1/chat/completions` endpoint, so the existing
`/v1/chat` and `/v1/execute` contracts do not change. No API key is required.

Set in Day 3's `.env`:

```bash
OLLAMA_ENABLED=true
OLLAMA_BASE_URL=http://192.168.0.137:11434
OLLAMA_DEFAULT_MODEL=<exact-model-name-from-ollama-list>
# Optional comma-separated catalog used by capability routing:
OLLAMA_MODELS=<model-a>,<model-b>
OLLAMA_TIMEOUT_MS=120000
```

Use the Ollama host's reachable LAN address when Day 3 runs on another
machine/container host. Do not use `localhost` from inside the Day 3
container to reach a different host. If both containers share a Docker
network, a service DNS name such as `http://llm:11434` is also suitable.

Only models listed in `OLLAMA_MODELS` are advertised to capability routing;
`OLLAMA_DEFAULT_MODEL` must be an exact installed model name. Verify it on
the Ollama host with `ollama list`. The adapter checks availability via
`GET /api/tags`, executes via `POST /v1/chat/completions`, normalizes token
usage, and maps network/timeouts/model errors to the existing provider error
contract. Ollama remains an optional provider; Groq/Gemini capability
preferences retain precedence unless explicitly routed to Ollama.

Example:

```json
{
  "provider": "ollama",
  "model": "<exact-installed-model>",
  "messages": [{ "role": "user", "content": "Hello from local inference" }]
}
```

## Gemini (future provider)

Gemini is declared in the registry (`enabled`, may be `configured`) but
`implemented` is always `false` in Day 3. No execution is faked — both
`/v1/chat` and `/v1/execute` return `PROVIDER_NOT_IMPLEMENTED` for
`provider: "gemini"`, and automatic routing never selects it. Adding
Gemini later means implementing `src/providers/gemini.js` with an
`execute()` function and wiring it into `src/providers/registry.js` —
the routing contract, `/v1/chat`, and `/v1/execute` do not change.

## Testing

```bash
./deploy-ai-gateway-3-of-10.sh test
```

Runs infrastructure checks (health/ready/dependencies/providers/help/metrics)
and a real `POST /v1/chat` against Groq when `GROQ_API_KEY` is configured.
The script distinguishes:

- Infrastructure test passed
- Provider configuration missing
- Provider execution passed
- Provider execution failed

## Observability

Metrics exposed at `GET /metrics` (Prometheus format):

- `chat_requests_total`, `chat_requests_success_total`, `chat_requests_failed_total`
- `execute_requests_total`, `execute_requests_success_total`, `execute_requests_failed_total`
- `provider_requests_total`, `provider_requests_success_total`, `provider_requests_failed_total` (labeled by provider/model)
- `provider_request_duration_seconds` (labeled by provider/model)

Prometheus: http://localhost:9095
Grafana: http://localhost:3005 (default admin / value of GRAFANA_ADMIN_PASSWORD)

## Troubleshooting

- `./deploy-ai-gateway-3-of-10.sh ps` — check container status
- `./deploy-ai-gateway-3-of-10.sh logs` — tail API logs
- `GET /ready` returning 503 — check Postgres/Redis containers are healthy
- `PROVIDER_NOT_CONFIGURED` — set `GROQ_API_KEY` in `.env` and run `restart`
- `PROVIDER_UNAVAILABLE` — no implemented+enabled+configured provider exists

## Future provider extension

To add a new provider (e.g. Gemini):

1. Create `src/providers/<name>.js` exporting `execute()` and `healthCheck()`
2. Register it in `src/providers/registry.js` with `implemented: true`
3. Add its env vars to `.env.example`
4. No changes required to `src/routes/chat.js`, `src/routes/execute.js`,
   `src/lib/executionService.js`, or the routing contract — and no changes
   required in Stack 5.
# PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT
# PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT
