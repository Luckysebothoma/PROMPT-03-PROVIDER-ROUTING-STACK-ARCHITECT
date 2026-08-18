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
  +----> Gemini (registry-only, not implemented)
```

Stack 3 resolves `provider`, `model`, routing strategy, and request
configuration, then executes the request against an implemented provider.

## Directory structure

```
PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT/
  src/
    server.js              Express app entrypoint
    routes/meta.js          /health /ready /dependencies /providers /help /metrics
    routes/chat.js           POST /v1/chat
    lib/config.js            env-driven configuration
    lib/logger.js            structured JSON logging
    lib/metrics.js           Prometheus metrics
    lib/db.js                Postgres pool + request_log persistence
    lib/redisClient.js       Redis client + routing state
    lib/router.js            provider resolution strategy
    providers/registry.js    provider registry (implemented/enabled/configured)
    providers/groq.js        Groq execution implementation
  db/init/001_init.sql       request_log table
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
- `POST /v1/chat` — route + execute a chat request

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

## Gemini (future provider)

Gemini is declared in the registry (`enabled`, may be `configured`) but
`implemented` is always `false` in Day 3. No execution is faked. Adding
Gemini later means implementing `src/providers/gemini.js` with an
`execute()` function and wiring it into `src/providers/registry.js` —
the routing contract and `/v1/chat` API do not change.

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
4. No changes required to `src/routes/chat.js` or the routing contract
# PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT
