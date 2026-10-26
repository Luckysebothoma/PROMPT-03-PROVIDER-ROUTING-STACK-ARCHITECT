-- AI Gateway telemetry / observability migration (additive, idempotent).
-- Safe on empty or populated databases. No drops, no truncates, no FK coupling.
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('aig_ai_telemetry_migration'));

-- Model registry: NULL capability = unknown (never assumed). Limits are documented/believed values,
-- kept separate from observed rate-limit telemetry (aig_rate_limit_observations).
CREATE TABLE IF NOT EXISTS aig_models (
  id                        BIGSERIAL PRIMARY KEY,
  provider                  TEXT NOT NULL,
  model_id                  TEXT NOT NULL,
  display_name              TEXT,
  model_family              TEXT,
  model_version             TEXT,
  active                    BOOLEAN NOT NULL DEFAULT TRUE,
  enabled                   BOOLEAN NOT NULL DEFAULT TRUE,
  fallback_eligible         BOOLEAN NOT NULL DEFAULT FALSE,
  supports_text             BOOLEAN,
  supports_vision           BOOLEAN,
  supports_image_input      BOOLEAN,
  supports_image_output     BOOLEAN,
  supports_audio            BOOLEAN,
  supports_tools            BOOLEAN,
  supports_function_calling BOOLEAN,
  supports_structured_output BOOLEAN,
  supports_reasoning        BOOLEAN,
  supports_prompt_caching   BOOLEAN,
  supports_context_caching  BOOLEAN,
  context_window            INT,
  max_input_tokens          INT,
  max_output_tokens         INT,
  rate_limits               JSONB NOT NULL DEFAULT '{}'::jsonb,
  availability              TEXT NOT NULL DEFAULT 'unknown',
  priority                  INT NOT NULL DEFAULT 100,
  fallback_priority         INT NOT NULL DEFAULT 100,
  metadata                  JSONB NOT NULL DEFAULT '{}'::jsonb,
  documentation_url         TEXT,
  discovered_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_verified_at          TIMESTAMPTZ,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT aig_models_provider_model_uq UNIQUE (provider, model_id)
);

CREATE TABLE IF NOT EXISTS aig_provider_config_snapshots (
  id        BIGSERIAL PRIMARY KEY,
  provider  TEXT NOT NULL,
  config    JSONB NOT NULL DEFAULT '{}'::jsonb,
  taken_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_requests (
  request_id          UUID PRIMARY KEY,
  trace_id            TEXT,
  session_id          TEXT,
  conversation_id     TEXT,
  parent_request_id   UUID,
  agent_name          TEXT,
  worker              TEXT,
  task                TEXT,
  request_type        TEXT NOT NULL DEFAULT 'chat',
  requested_provider  TEXT,
  requested_model     TEXT,
  final_provider      TEXT,
  final_model         TEXT,
  endpoint            TEXT,
  model_version       TEXT,
  routing_reason      TEXT,
  success             BOOLEAN NOT NULL DEFAULT FALSE,
  http_status         INT,
  retry_count         INT NOT NULL DEFAULT 0,
  fallback_used       BOOLEAN NOT NULL DEFAULT FALSE,
  fallback_count      INT NOT NULL DEFAULT 0,
  fallback_reason     TEXT,
  temperature         DOUBLE PRECISION,
  max_tokens          INT,
  top_p               DOUBLE PRECISION,
  seed                BIGINT,
  tools               JSONB,
  response_format     JSONB,
  request_metadata    JSONB,
  normalized_request  JSONB,
  input_tokens        INT,
  output_tokens       INT,
  total_tokens        INT,
  cached_tokens       INT,
  image_count         INT NOT NULL DEFAULT 0,
  input_truncated     BOOLEAN NOT NULL DEFAULT FALSE,
  error_class         TEXT,
  error_message       TEXT,
  started_at          TIMESTAMPTZ NOT NULL,
  completed_at        TIMESTAMPTZ,
  duration_ms         INT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_messages (
  id          BIGSERIAL PRIMARY KEY,
  request_id  UUID NOT NULL,
  seq         INT NOT NULL,
  role        TEXT,
  name        TEXT,
  content     JSONB,
  content_text TEXT,
  has_images  BOOLEAN NOT NULL DEFAULT FALSE,
  truncated   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per external provider call (including retries / key rotation / fallbacks).
CREATE TABLE IF NOT EXISTS aig_attempts (
  attempt_id                  UUID PRIMARY KEY,
  request_id                  UUID NOT NULL,
  attempt_number              INT NOT NULL,
  provider                    TEXT NOT NULL,
  model                       TEXT,
  provider_account_ref        TEXT,
  endpoint                    TEXT,
  started_at                  TIMESTAMPTZ,
  ended_at                    TIMESTAMPTZ,
  duration_ms                 INT,
  http_status                 INT,
  success                     BOOLEAN NOT NULL DEFAULT FALSE,
  is_fallback                 BOOLEAN NOT NULL DEFAULT FALSE,
  fallback_reason             TEXT,
  error_class                 TEXT,
  is_timeout                  BOOLEAN NOT NULL DEFAULT FALSE,
  retry_after_sec             DOUBLE PRECISION,
  finish_reason               TEXT,
  system_fingerprint          TEXT,
  provider_request_id         TEXT,
  input_tokens                INT,
  output_tokens               INT,
  total_tokens                INT,
  cached_tokens               INT,
  reasoning_tokens            INT,
  tool_tokens                 INT,
  estimated_input_tokens      INT,
  estimated_output_tokens     INT,
  tokens_estimated            BOOLEAN NOT NULL DEFAULT FALSE,
  requested_max_tokens        INT,
  documented_context_window   INT,
  documented_max_input_tokens INT,
  documented_max_output_tokens INT,
  remaining_context_tokens    INT,
  usage                       JSONB,
  response_headers            JSONB,
  provider_metadata           JSONB,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_responses (
  response_id       BIGSERIAL PRIMARY KEY,
  request_id        UUID NOT NULL,
  attempt_id        UUID,
  provider          TEXT,
  model             TEXT,
  content_text      TEXT,
  content           JSONB,
  finish_reason     TEXT,
  truncated         BOOLEAN NOT NULL DEFAULT FALSE,
  response_metadata JSONB,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_rate_limit_observations (
  id                   BIGSERIAL PRIMARY KEY,
  request_id           UUID,
  attempt_id           UUID,
  provider             TEXT NOT NULL,
  model                TEXT,
  provider_account_ref TEXT,
  observed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  http_status          INT,
  is_rate_limited      BOOLEAN NOT NULL DEFAULT FALSE,
  retry_after_sec      DOUBLE PRECISION,
  limit_requests       BIGINT,
  limit_tokens         BIGINT,
  remaining_requests   BIGINT,
  remaining_tokens     BIGINT,
  reset_requests_raw   TEXT,
  reset_tokens_raw     TEXT,
  reset_requests_at    TIMESTAMPTZ,
  reset_tokens_at      TIMESTAMPTZ,
  believed_limits      JSONB,
  raw_headers          JSONB
);

CREATE TABLE IF NOT EXISTS aig_fallback_events (
  id                      BIGSERIAL PRIMARY KEY,
  request_id              UUID NOT NULL,
  attempt_number          INT,
  original_provider       TEXT,
  original_model          TEXT,
  failure_reason          TEXT,
  http_status             INT,
  retry_after_sec         DOUBLE PRECISION,
  fallback_provider       TEXT,
  fallback_model          TEXT,
  fallback_attempt_number INT,
  final_provider          TEXT,
  final_model             TEXT,
  total_fallback_count    INT,
  routing_decision        JSONB,
  occurred_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_errors (
  id                     BIGSERIAL PRIMARY KEY,
  request_id             UUID,
  attempt_id             UUID,
  provider               TEXT,
  model                  TEXT,
  request_type           TEXT,
  error_class            TEXT,
  http_status            INT,
  provider_error_code    TEXT,
  provider_error_message TEXT,
  retryable              BOOLEAN,
  retry_after_sec        DOUBLE PRECISION,
  is_timeout             BOOLEAN NOT NULL DEFAULT FALSE,
  is_context_limit       BOOLEAN NOT NULL DEFAULT FALSE,
  is_rate_limit          BOOLEAN NOT NULL DEFAULT FALSE,
  is_validation          BOOLEAN NOT NULL DEFAULT FALSE,
  fallback_decision      TEXT,
  final_result           TEXT,
  stack_trace            TEXT,
  sanitized_payload      JSONB,
  occurred_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_cache_events (
  id               BIGSERIAL PRIMARY KEY,
  request_id       UUID,
  attempt_id       UUID,
  provider         TEXT,
  model            TEXT,
  cache_type       TEXT,
  cache_requested  BOOLEAN,
  cache_hit        BOOLEAN,
  cached_tokens    INT,
  cache_ref        TEXT,
  cache_created_at TIMESTAMPTZ,
  cache_expires_at TIMESTAMPTZ,
  ttl_seconds      INT,
  metadata         JSONB,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_vision_inputs (
  id              BIGSERIAL PRIMARY KEY,
  request_id      UUID NOT NULL,
  provider        TEXT,
  model           TEXT,
  image_index     INT,
  source_type     TEXT,
  mime_type       TEXT,
  size_bytes      BIGINT,
  url_ref         TEXT,
  storage_ref     TEXT,
  content_hash    TEXT,
  width           INT,
  height          INT,
  ocr_metadata    JSONB,
  vision_metadata JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aig_generated_images (
  image_id          UUID PRIMARY KEY,
  request_id        UUID,
  provider          TEXT,
  model             TEXT,
  generation_id     TEXT,
  image_url         TEXT,
  storage_ref       TEXT,
  retrievable       BOOLEAN NOT NULL DEFAULT FALSE,
  mime_type         TEXT,
  width             INT,
  height            INT,
  file_size_bytes   BIGINT,
  image_hash        TEXT,
  prompt            TEXT,
  negative_prompt   TEXT,
  seed              BIGINT,
  parameters        JSONB,
  provider_metadata JSONB,
  success           BOOLEAN,
  latency_ms        INT,
  error_message     TEXT,
  reproducible      BOOLEAN,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Training / evaluation readiness. Scores are only stored when supplied by a real evaluation process.
CREATE TABLE IF NOT EXISTS aig_dataset_items (
  id                  BIGSERIAL PRIMARY KEY,
  request_id          UUID,
  attempt_id          UUID,
  image_id            UUID,
  label               TEXT,   -- training_candidate | evaluation_candidate | rejected | reviewed | regression_sample
  quality             TEXT,   -- high | low | NULL (unknown)
  human_reviewed      BOOLEAN NOT NULL DEFAULT FALSE,
  auto_evaluated      BOOLEAN NOT NULL DEFAULT FALSE,
  quality_score       DOUBLE PRECISION,
  evaluation_metadata JSONB,
  human_feedback      TEXT,
  tags                JSONB,
  dataset_name        TEXT,
  dataset_version     TEXT,
  inclusion_status    TEXT NOT NULL DEFAULT 'pending',
  created_by          TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS aig_models_selection_idx ON aig_models (provider, enabled, fallback_priority);
CREATE INDEX IF NOT EXISTS aig_provider_cfg_idx ON aig_provider_config_snapshots (provider, taken_at DESC);
CREATE INDEX IF NOT EXISTS aig_requests_started_idx ON aig_requests (started_at DESC);
CREATE INDEX IF NOT EXISTS aig_requests_final_idx ON aig_requests (final_provider, final_model, started_at DESC);
CREATE INDEX IF NOT EXISTS aig_requests_trace_idx ON aig_requests (trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS aig_requests_session_idx ON aig_requests (session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS aig_requests_conv_idx ON aig_requests (conversation_id) WHERE conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS aig_requests_parent_idx ON aig_requests (parent_request_id) WHERE parent_request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS aig_requests_fallback_idx ON aig_requests (started_at DESC) WHERE fallback_used;
CREATE INDEX IF NOT EXISTS aig_requests_failed_idx ON aig_requests (started_at DESC) WHERE NOT success;
CREATE INDEX IF NOT EXISTS aig_messages_request_idx ON aig_messages (request_id, seq);
CREATE INDEX IF NOT EXISTS aig_attempts_request_idx ON aig_attempts (request_id, attempt_number);
CREATE INDEX IF NOT EXISTS aig_attempts_model_idx ON aig_attempts (provider, model, started_at DESC);
CREATE INDEX IF NOT EXISTS aig_attempts_429_idx ON aig_attempts (provider, model, started_at DESC) WHERE http_status = 429;
CREATE INDEX IF NOT EXISTS aig_responses_request_idx ON aig_responses (request_id);
CREATE INDEX IF NOT EXISTS aig_ratelimit_model_idx ON aig_rate_limit_observations (provider, model, observed_at DESC);
CREATE INDEX IF NOT EXISTS aig_ratelimit_request_idx ON aig_rate_limit_observations (request_id);
CREATE INDEX IF NOT EXISTS aig_ratelimit_hits_idx ON aig_rate_limit_observations (provider, model, observed_at DESC) WHERE is_rate_limited;
CREATE INDEX IF NOT EXISTS aig_fallback_request_idx ON aig_fallback_events (request_id);
CREATE INDEX IF NOT EXISTS aig_fallback_orig_idx ON aig_fallback_events (original_provider, original_model, occurred_at DESC);
CREATE INDEX IF NOT EXISTS aig_fallback_target_idx ON aig_fallback_events (fallback_provider, fallback_model);
CREATE INDEX IF NOT EXISTS aig_errors_request_idx ON aig_errors (request_id);
CREATE INDEX IF NOT EXISTS aig_errors_model_idx ON aig_errors (provider, model, occurred_at DESC);
CREATE INDEX IF NOT EXISTS aig_errors_class_idx ON aig_errors (error_class, occurred_at DESC);
CREATE INDEX IF NOT EXISTS aig_cache_request_idx ON aig_cache_events (request_id);
CREATE INDEX IF NOT EXISTS aig_cache_model_idx ON aig_cache_events (provider, model, created_at DESC);
CREATE INDEX IF NOT EXISTS aig_vision_request_idx ON aig_vision_inputs (request_id);
CREATE INDEX IF NOT EXISTS aig_vision_hash_idx ON aig_vision_inputs (content_hash) WHERE content_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS aig_genimg_request_idx ON aig_generated_images (request_id);
CREATE INDEX IF NOT EXISTS aig_genimg_hash_idx ON aig_generated_images (image_hash) WHERE image_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS aig_genimg_model_idx ON aig_generated_images (provider, model, created_at DESC);
CREATE INDEX IF NOT EXISTS aig_dataset_request_idx ON aig_dataset_items (request_id);
CREATE INDEX IF NOT EXISTS aig_dataset_set_idx ON aig_dataset_items (dataset_name, dataset_version, inclusion_status);
CREATE INDEX IF NOT EXISTS aig_dataset_label_idx ON aig_dataset_items (label);

COMMIT;
