# AI Gateway telemetry (database-first)

Every external AI call becomes durable PostgreSQL data (tables prefixed `aig_`, no foreign keys, additive only).
Persistence is asynchronous, batched, bounded and fail-open: database trouble never fails or slows a provider call.
Telemetry reuses the existing pool in `src/lib/db.js` (POSTGRES_* from `.env`) and registers `aig_*` metrics on the
existing Registry exported by `src/lib/metrics.js`. The legacy `request_log` table and `recordRequest` are untouched.

## Migration
`db/init/NNN_aig_ai_telemetry.sql` is idempotent (`IF NOT EXISTS`). The upgrade script applied it to the running database
(PostgreSQL runs outside this compose project) and wrote a pre-migration dump to `.patch-backups/aig-upgrade-<ts>-<pid>/db-premigration.sql.gz`.
Re-apply manually with any psql client, e.g.
`docker run --rm -i --network databases -e PGPASSWORD=... postgres:18-alpine psql -h <host> -U <user> -d <db> -v ON_ERROR_STOP=1 < db/init/NNN_aig_ai_telemetry.sql`

## Tables
| Table | Purpose |
|---|---|
| aig_requests | one row per logical request: routing, params, final provider/model, fallback counts, final tokens |
| aig_messages | normalised input messages (image bytes replaced by hash/size/type references) |
| aig_attempts | one row per provider call (retry / key rotation / fallback): status, latency, tokens, cached tokens, headers, usage |
| aig_responses | output text/tool calls, finish reason, response metadata |
| aig_rate_limit_observations | Groq `x-ratelimit-*` / `retry-after` headers, 429 flag, believed limits at the time |
| aig_fallback_events | full provider/model switch chain per request |
| aig_errors | failure dataset: class, status, provider code/message, retryable, timeout/context/rate flags, sanitised payload |
| aig_cache_events | prompt caching (`cached_tokens`) and Gemini context-cache metadata |
| aig_vision_inputs | per-image metadata: source type, mime, size, sha256, dimensions, sanitised URL |
| aig_generated_images | request -> prompt -> provider/model -> params -> image hash/storage ref/result |
| aig_models | model registry: capabilities (NULL = unknown), documented limits, priorities, `fallback_eligible` |
| aig_provider_config_snapshots | redacted provider configuration history |
| aig_dataset_items | training/evaluation candidates; scores stored only when supplied by a real evaluation |

Documented limits (`aig_models`, `documented_*` on attempts), request limits (`requested_max_tokens`) and actual usage
(`*_tokens`) are stored separately. Provider limits are data, not code: edit `aig_models.rate_limits` / context columns.

## Routing, fallback and chaining
Groq provider order: requested model -> `GROQ_FALLBACK_MODELS` -> `aig_models` rows with `fallback_eligible = true`
(sorted by `fallback_priority`). Models known to lack vision (`supports_vision = false`), disabled/unavailable models and models
whose `context_window` is too small are skipped. Keys come from `GROQ_API_KEY_1..N`; cooldowns are per key **and** model
(honouring `retry-after`). Groq limits apply per organisation, so rotation only helps for keys from different orgs.
Other providers (e.g. `gemini.js`) are wrapped additively by `src/lib/instrument.js`. When the caller passes the same UUID
`request_id`/`requestId` to several providers (a router falling back groq -> gemini), the calls are chained: attempts are
renumbered, `aig_requests` is updated and a cross-provider row is written to `aig_fallback_events`.
Gemini API-key rotation is not applied automatically (`src/lib/keyPool.js` can be reused for `GEMINI_API_KEY_1..N`).

## Images
Image bytes are never stored in PostgreSQL. Vision inputs keep sha256/size/mime/dimensions; URLs lose query strings and credentials.
Generated images keep hash/size/dimensions/prompt/params; set `AIG_IMAGE_STORE_DIR` (a mounted volume) to also persist the bytes
under a hash-derived name and record `storage_ref = fs:<relpath>`.

## Environment variables
`GROQ_API_KEY_1..N`, `GEMINI_API_KEY_1..N`, `GROQ_FALLBACK_MODELS`, `GROQ_TIMEOUT_MS`, `AIG_MAX_TOTAL_MS`, `AIG_TELEMETRY_ENABLED`,
`AIG_STORE_PAYLOADS` (false = do not store prompt/response text), `AIG_MAX_TEXT_BYTES`, `AIG_TELEMETRY_MAX_QUEUE`,
`AIG_TELEMETRY_FLUSH_MS`, `AIG_IMAGE_STORE_DIR`. Database settings are the existing `POSTGRES_*` variables.

## Metrics (registered on the existing Registry, low-cardinality labels)
`aig_ai_requests_total`, `aig_ai_request_duration_seconds`, `aig_ai_tokens_total`, `aig_ai_fallbacks_total`,
`aig_ai_rate_limited_total`, `aig_ai_timeouts_total`, `aig_ai_vision_requests_total`, `aig_ai_image_generations_total`, `aig_ai_cache_events_total`.

## Rollback
Files: `./upgrade-ai-gateway.sh --rollback-files .patch-backups/aig-upgrade-<ts>-<pid>` then rebuild the API service.
Database: the migration only adds `aig_*` objects and is harmless to leave. To undo completely, restore the dump, or (manually,
deliberately) `DROP TABLE aig_...`. The script never drops or truncates anything.

## Verification
```sql
SELECT provider, model, count(*), avg(duration_ms) FROM aig_attempts WHERE started_at > now() - interval '1 day' GROUP BY 1,2;
SELECT * FROM aig_fallback_events ORDER BY occurred_at DESC LIMIT 10;
SELECT provider, model, count(*) FROM aig_rate_limit_observations WHERE is_rate_limited GROUP BY 1,2;
```
