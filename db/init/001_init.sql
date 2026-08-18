-- Stack 3 - Provider Routing & Execution
-- Minimal request metadata table. Provider *configuration* itself lives
-- in Stack 2's registry; this stack does not duplicate that data. It only
-- persists routing/execution request metadata for observability/audit.

CREATE TABLE IF NOT EXISTS request_log (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL,
  provider      TEXT,
  model         TEXT,
  success       BOOLEAN NOT NULL,
  error_code    TEXT,
  duration_ms   INTEGER,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_request_log_created_at ON request_log (created_at);
CREATE INDEX IF NOT EXISTS idx_request_log_provider ON request_log (provider);
