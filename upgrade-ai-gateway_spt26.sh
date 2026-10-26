#!/usr/bin/env bash
# =============================================================================
# AI Gateway in-place upgrade: DB-first AI observability, provider resilience,
# vision, caching and training-data readiness.   (v2: external Swarm PostgreSQL)
#
# Run from inside the gateway repository (or set AIG_REPO_ROOT).
#   ./upgrade-ai-gateway.sh [--dry-run] [--no-restart] [--skip-tests]
#                           [--rollback-files <backup-dir>] [-h]
#
# Database access: connection details are read from the repo's .env
# (POSTGRES_HOST/PORT/DB/USER/PASSWORD, same names as src/lib/config.js).
# SQL is executed through the gateway's own image (node + pg) on its own
# networks; pg_dump runs in a throwaway postgres container on the same network.
#
# Env overrides: AIG_REPO_ROOT AIG_API_SERVICE AIG_COMPOSE_FILE AIG_DB_NETWORK
#   AIG_PG_IMAGE AIG_ALLOW_NO_BACKUP=1 AIG_NO_RESTART=1 AIG_SKIP_TESTS=1
#   AIG_NO_AUTO_ROLLBACK=1
#
# Exit codes: 0 ok | 2 usage/missing tools | 3 repo structure | 4 database
#   5 migration verification | 6 syntax | 7 app start/health | 8 telemetry check
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

DRY_RUN=0
NO_RESTART="${AIG_NO_RESTART:-0}"
SKIP_TESTS="${AIG_SKIP_TESTS:-0}"
ROLLBACK_DIR=""
COMPLETED=0
FILES_CHANGED=0
RESTARTED=0
NO_ROLLBACK=0
BACKUP_DIR=""
ROOT=""
COMPOSE=()
API_SERVICE=""
PGH="" PGP="" PGD="" PGU="" PGPW=""
DB_NET=""
PGENV=""
CHANGED_JS=()

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { local code="$1"; shift; printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit "$code"; }

usage() { sed -n '2,20p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; }

on_err() { warn "command failed at line $2 (exit $1)"; }
trap 'on_err $? $LINENO' ERR

cleanup() {
  local code=$?
  [[ -n "$PGENV" ]] && rm -f "$PGENV"
  if [[ $code -ne 0 && $COMPLETED -eq 0 && $FILES_CHANGED -eq 1 && $NO_ROLLBACK -eq 0 \
        && -z "${AIG_NO_AUTO_ROLLBACK:-}" && -n "$BACKUP_DIR" ]]; then
    warn "upgrade failed (exit $code): restoring modified files from $BACKUP_DIR"
    restore_files "$BACKUP_DIR" || warn "file restore reported problems"
    if [[ $RESTARTED -eq 1 && ${#COMPOSE[@]} -gt 0 && -n "$API_SERVICE" ]]; then
      warn "rebuilding previous application version"
      ( cd "$ROOT" && "${COMPOSE[@]}" up -d --build "$API_SERVICE" ) >/dev/null 2>&1 || warn "rebuild of previous version failed; do it manually"
    fi
    warn "database changes are additive (aig_* tables) and were left in place"
  fi
  exit "$code"
}
trap cleanup EXIT

# ------------------------------------------------------------------ arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --rollback-files) shift; ROLLBACK_DIR="${1:-}" ;;
    -h|--help) usage; COMPLETED=1; exit 0 ;;
    *) usage; die 2 "unknown argument: $1" ;;
  esac
  shift
done

# ------------------------------------------------------------------ helpers
restore_files() {
  local dir="$1" manifest="$1/manifest.tsv" kind rel
  [[ -f "$manifest" ]] || { warn "no manifest in $dir"; return 1; }
  while IFS=$'\t' read -r kind rel; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      M) if [[ -f "$dir/files/$rel" ]]; then cp -p "$dir/files/$rel" "$ROOT/$rel"; log "restored $rel"; fi ;;
      C) if [[ -f "$ROOT/$rel" ]]; then rm -f "$ROOT/$rel"; log "removed created file $rel"; fi ;;
    esac
  done < <(tac "$manifest")
}

backup_file() { # $1 = repo-relative path (existing file)
  local rel="$1"
  mkdir -p "$BACKUP_DIR/files/$(dirname "$rel")"
  if [[ ! -e "$BACKUP_DIR/files/$rel" ]]; then
    cp -p "$ROOT/$rel" "$BACKUP_DIR/files/$rel"
    printf 'M\t%s\n' "$rel" >> "$BACKUP_DIR/manifest.tsv"
  fi
}

install_file() { # $1 = repo-relative destination; content on stdin
  local rel="$1" dest="$ROOT/$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; log "unchanged: $rel"; return 0
  fi
  if [[ -f "$dest" ]]; then backup_file "$rel"; else printf 'C\t%s\n' "$rel" >> "$BACKUP_DIR/manifest.tsv"; fi
  mkdir -p "$(dirname "$dest")"
  cat "$tmp" > "$dest"
  rm -f "$tmp"
  FILES_CHANGED=1
  [[ "$rel" == *.js ]] && CHANGED_JS+=("$rel")
  log "wrote: $rel"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die 2 "required command not found: $1"; }

# read KEY from .env without sourcing it (no code execution); prints nothing if absent
env_get() {
  local k="$1" line v
  [[ -f .env ]] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" .env | tail -1 || true)"
  [[ -n "$line" ]] || return 0
  v="${line#*=}"; v="${v%$'\r'}"
  v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# --- database access through the gateway image (node + pg), using the container's own .env-provided config
DB_JS="$(cat <<'AIG_DBJS_EOF'
const {Client}=require('pg');const e=process.env;
const c=new Client({host:e.POSTGRES_HOST||'postgres',port:parseInt(e.POSTGRES_PORT||'5432',10),database:e.POSTGRES_DB||'ai_gateway_routing',user:e.POSTGRES_USER||'ai_gateway',password:e.POSTGRES_PASSWORD||'',connectionTimeoutMillis:8000});
let s='';
process.stdin.on('data',d=>s+=d).on('end',async()=>{
  try{
    await c.connect();
    const r=await c.query(s);
    const last=Array.isArray(r)?r[r.length-1]:r;
    if(process.argv[1]==='rows'&&last&&last.rows){for(const row of last.rows){console.log('AIGROW\t'+Object.values(row).map(v=>v===null?'':String(v)).join('\t'));}}
    await c.end();
  }catch(err){console.error(err.message);process.exit(1);}
});
AIG_DBJS_EOF
)"

dbq() { # $1 = SQL; prints result rows (tab separated) on stdout
  local out rc=0
  out="$(printf '%s' "$1" | "${COMPOSE[@]}" run --rm --no-deps -T "$API_SERVICE" node -e "$DB_JS" rows 2>"$BACKUP_DIR/dbq.err")" || rc=$?
  if [[ $rc -ne 0 ]]; then cat "$BACKUP_DIR/dbq.err" >&2; return $rc; fi
  printf '%s\n' "$out" | { grep '^AIGROW' || true; } | cut -f2-
}

dbfile() { # $1 = file with SQL
  "${COMPOSE[@]}" run --rm --no-deps -T "$API_SERVICE" node -e "$DB_JS" exec < "$1" 2>"$BACKUP_DIR/dbfile.err" \
    || { cat "$BACKUP_DIR/dbfile.err" >&2; return 1; }
}

# ------------------------------------------------------------------ 0. locate repo
find_root() {
  local c
  for c in "${AIG_REPO_ROOT:-}" "$PWD" "$SCRIPT_DIR" "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"; do
    [[ -n "$c" && -f "$c/src/server.js" && -d "$c/src/providers" ]] && { ( cd "$c" && pwd ); return 0; }
  done
  return 1
}
ROOT="$(find_root)" || die 3 "cannot find gateway repository (expected src/server.js and src/providers). Run from the repo root or set AIG_REPO_ROOT."
cd "$ROOT"

if [[ -n "$ROLLBACK_DIR" ]]; then
  [[ -d "$ROLLBACK_DIR" ]] || die 2 "backup dir not found: $ROLLBACK_DIR"
  restore_files "$(cd "$ROLLBACK_DIR" && pwd)"
  log "file rollback complete. Rebuild the API service. Database aig_* tables were NOT dropped (see docs/AI_TELEMETRY.md)."
  COMPLETED=1; exit 0
fi

BACKUP_DIR="$ROOT/.patch-backups/aig-upgrade-$TS-$$"
mkdir -p "$BACKUP_DIR/files"
: > "$BACKUP_DIR/manifest.tsv"
exec > >(tee -a "$BACKUP_DIR/upgrade.log") 2>&1

log "repository root : $ROOT"
log "backup directory: $BACKUP_DIR"

# ------------------------------------------------------------------ 1. preflight
for c in bash docker node grep sed awk gzip cmp mktemp tac sort comm date cut; do need_cmd "$c"; done
if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else die 2 "docker compose is not available"; fi
docker info >/dev/null 2>&1 || die 2 "docker daemon is not reachable by this user"

COMPOSE_FILE_FOUND=""
if [[ -n "${AIG_COMPOSE_FILE:-}" ]]; then COMPOSE_FILE_FOUND="$AIG_COMPOSE_FILE"; COMPOSE+=(-f "$AIG_COMPOSE_FILE")
else
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f "$f" ]] && { COMPOSE_FILE_FOUND="$f"; break; }
  done
fi
[[ -n "$COMPOSE_FILE_FOUND" ]] || die 3 "no compose file found in $ROOT (set AIG_COMPOSE_FILE)"
log "compose file    : $COMPOSE_FILE_FOUND"

# ------------------------------------------------------------------ 2. inspect repository
log "--- inspecting repository ---"
for f in src/server.js src/providers/registry.js src/providers/groq.js src/lib/config.js; do
  [[ -f "$f" ]] || die 3 "expected file missing: $f (repository differs from expected architecture; nothing was modified)"
done
grep -q "module.exports" src/providers/groq.js && grep -q "ProviderError" src/providers/groq.js && grep -q "execute" src/providers/groq.js \
  || die 3 "src/providers/groq.js does not look like the expected provider module; refusing to modify"

log "src tree (depth 2):"; find src -maxdepth 2 -type f -name '*.js' | sort | sed 's/^/    /'
[[ -d db/init ]] && { log "db/init:"; ls db/init | sed 's/^/    /'; } || warn "db/init not found; it will be created"

PKG_INFO="$(node -e '
const p=require("./package.json");const d=Object.assign({},p.dependencies,p.devDependencies);
console.log(["pg","prom-client","node-fetch","express"].map(k=>k+"="+(d[k]||"-")).join(" "));
console.log("test="+((p.scripts&&p.scripts.test)||"-"));' 2>/dev/null)" || die 3 "cannot read package.json"
log "deps: $(echo "$PKG_INFO" | head -1)"
HAS_PG="$(node -e 'const p=require("./package.json");process.stdout.write((p.dependencies&&p.dependencies.pg)||(p.devDependencies&&p.devDependencies.pg)?"1":"0")')"

if [[ -f src/lib/db.js ]] && grep -q "pool" src/lib/db.js; then log "existing src/lib/db.js pool detected: telemetry will reuse it"; else warn "src/lib/db.js not found: telemetry will build its own pool from POSTGRES_* env"; fi
if node -e 'const m=require("./src/lib/metrics");process.exit(m.register&&typeof m.register.getSingleMetric==="function"?0:1)' >/dev/null 2>&1; then
  log "src/lib/metrics.js exports its Registry: aig_* metrics will be added to the existing /metrics registry"
else
  warn "src/lib/metrics.js does not export 'register'; aig_* metrics will use the prom-client default registry (may not appear on /metrics)"
fi

if git check-ignore -q src/lib/keyPool.js 2>/dev/null; then warn "src/lib/keyPool.js is git-ignored: new files would not be committed. Fix .gitignore."; fi
if [[ -f .dockerignore ]] && grep -nEq '^(/)?(src/)?(\*\*/)?lib/?$' .dockerignore; then
  die 3 ".dockerignore excludes a 'lib' directory: new src/lib files would never reach the image. Fix .dockerignore and re-run."
fi

SERVICES="$("${COMPOSE[@]}" config --services 2>/dev/null)" || die 3 "compose config is invalid"
log "compose services: $(echo "$SERVICES" | tr '\n' ' ')"
API_SERVICE="${AIG_API_SERVICE:-$(echo "$SERVICES" | grep -Ex 'api|gateway|ai-gateway' | head -1 || true)}"
[[ -n "$API_SERVICE" ]] || API_SERVICE="$(echo "$SERVICES" | grep -Ei 'api|gateway' | head -1 || true)"
[[ -n "$API_SERVICE" ]] || die 3 "cannot detect gateway service (set AIG_API_SERVICE)"
log "api service: $API_SERVICE"

# database target from .env (same names and defaults as src/lib/config.js)
[[ -f .env ]] || warn ".env not found: using defaults from src/lib/config.js"
PGH="$(env_get POSTGRES_HOST)"; PGH="${PGH:-postgres}"
PGP="$(env_get POSTGRES_PORT)"; PGP="${PGP:-5432}"
PGD="$(env_get POSTGRES_DB)";   PGD="${PGD:-ai_gateway_routing}"
PGU="$(env_get POSTGRES_USER)"; PGU="${PGU:-ai_gateway}"
PGPW="$(env_get POSTGRES_PASSWORD)"
[[ -n "$PGPW" ]] || warn "POSTGRES_PASSWORD not found in .env (empty password will be used)"
log "database target: $PGU@$PGH:$PGP/$PGD (password not printed)"

# network the api container uses to reach PostgreSQL
DB_NET="${AIG_DB_NETWORK:-$("${COMPOSE[@]}" config --format json 2>/dev/null | API_SVC="$API_SERVICE" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const c=JSON.parse(s);const nets=Object.keys((c.services[process.env.API_SVC]||{}).networks||{});
const pick=nets.find(n=>/database|postgres|db/i.test(n))||nets[0]||"";const def=(c.networks||{})[pick]||{};process.stdout.write(def.name||pick)}catch(e){}})' || true)}"
DB_NET="${DB_NET:-databases}"
log "database network: $DB_NET (attachable: $(docker network inspect "$DB_NET" --format '{{.Attachable}}' 2>/dev/null || echo unknown))"

if [[ $DRY_RUN -eq 1 ]]; then log "dry run: inspection finished, nothing modified"; COMPLETED=1; exit 0; fi

# ------------------------------------------------------------------ 3. database connectivity + backup
log "--- database ---"
CHECK="$(dbq "SELECT current_database(), current_user, current_setting('server_version_num')")" \
  || die 4 "cannot connect to PostgreSQL through the gateway image. Check POSTGRES_* in .env and that network '$DB_NET' is reachable."
[[ -n "$CHECK" ]] || die 4 "connectivity check returned no rows"
SRV_NUM="$(echo "$CHECK" | cut -f3)"
PG_MAJOR=$(( SRV_NUM / 10000 ))
log "connected: db=$(echo "$CHECK" | cut -f1) user=$(echo "$CHECK" | cut -f2) server_major=$PG_MAJOR"

dbq "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1" | sort > "$BACKUP_DIR/tables-before.txt"
log "existing public tables: $(wc -l < "$BACKUP_DIR/tables-before.txt") ($(paste -sd' ' "$BACKUP_DIR/tables-before.txt" | cut -c1-200))"

DB_BACKUP="$BACKUP_DIR/db-premigration.sql.gz"
[[ ! -e "$DB_BACKUP" ]] || die 4 "backup path already exists: $DB_BACKUP"
PG_IMAGE="${AIG_PG_IMAGE:-postgres:${PG_MAJOR}-alpine}"
PGENV="$(mktemp)"; chmod 600 "$PGENV"; printf 'PGPASSWORD=%s\n' "$PGPW" > "$PGENV"
log "creating database backup with $PG_IMAGE on network $DB_NET: $DB_BACKUP"
if docker run --rm --network "$DB_NET" --env-file "$PGENV" "$PG_IMAGE" pg_dump -h "$PGH" -p "$PGP" -U "$PGU" -d "$PGD" --no-owner | gzip > "$DB_BACKUP" \
   && gzip -t "$DB_BACKUP" && [[ "$(wc -c < "$DB_BACKUP")" -gt 200 ]]; then
  log "backup OK ($(wc -c < "$DB_BACKUP") bytes)"
  echo "$DB_BACKUP" >> "$ROOT/.patch-backups/AIG_LAST_DB_BACKUPS.txt"
else
  rm -f "$DB_BACKUP"
  if [[ "${AIG_ALLOW_NO_BACKUP:-0}" == "1" ]]; then
    warn "pg_dump failed; continuing WITHOUT backup because AIG_ALLOW_NO_BACKUP=1 (migration is additive-only)"
    DB_BACKUP="(none)"
  else
    die 4 "pg_dump failed (network '$DB_NET' must be attachable and image '$PG_IMAGE' pullable). Set AIG_DB_NETWORK / AIG_PG_IMAGE, or AIG_ALLOW_NO_BACKUP=1 to proceed without a dump. Nothing was changed."
  fi
fi
rm -f "$PGENV"; PGENV=""

if [[ -f .gitignore ]] && ! grep -qF '.patch-backups/aig-upgrade-*/*.sql.gz' .gitignore; then
  backup_file .gitignore; printf '\n# AI gateway upgrade DB dumps (may contain data)\n.patch-backups/aig-upgrade-*/*.sql.gz\n' >> .gitignore; FILES_CHANGED=1
elif [[ ! -f .gitignore ]]; then
  printf '.patch-backups/aig-upgrade-*/*.sql.gz\n' | install_file .gitignore
fi

# ------------------------------------------------------------------ 4. migration
log "--- migration ---"
mkdir -p db/init
EXISTING_MIG="$(ls db/init/*aig_ai_telemetry*.sql 2>/dev/null | head -1 || true)"
if [[ -n "$EXISTING_MIG" ]]; then
  MIG_REL="$EXISTING_MIG"
else
  max=-1; width=3
  shopt -s nullglob
  for f in db/init/*; do
    b="$(basename "$f")"
    if [[ $b =~ ^([0-9]+) ]]; then
      n=$((10#${BASH_REMATCH[1]})); width=${#BASH_REMATCH[1]}
      if (( n > max )); then max=$n; fi
    fi
  done
  shopt -u nullglob
  MIG_REL="db/init/$(printf "%0${width}d" $((max+1)))_aig_ai_telemetry.sql"
fi
log "migration file: $MIG_REL"

install_file "$MIG_REL" <<'AIG_SQL_EOF'
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
AIG_SQL_EOF

log "applying migration (idempotent)"
dbfile "$ROOT/$MIG_REL" || die 5 "migration failed to apply (database backup: $DB_BACKUP). If the error is 'permission denied for schema public', grant CREATE on schema public to $PGU."

EXPECTED_TABLES=(aig_models aig_provider_config_snapshots aig_requests aig_messages aig_attempts aig_responses aig_rate_limit_observations aig_fallback_events aig_errors aig_cache_events aig_vision_inputs aig_generated_images aig_dataset_items)
EXPECTED_INDEXES=(aig_models_selection_idx aig_requests_started_idx aig_requests_final_idx aig_requests_trace_idx aig_messages_request_idx aig_attempts_request_idx aig_attempts_model_idx aig_attempts_429_idx aig_ratelimit_model_idx aig_fallback_request_idx aig_errors_model_idx aig_cache_model_idx aig_vision_request_idx aig_genimg_request_idx aig_dataset_set_idx)
arr_sql() { local out="" x; for x in "$@"; do out+="'$x',"; done; printf 'ARRAY[%s]::text[]' "${out%,}"; }
MISSING_T="$(dbq "SELECT t FROM unnest($(arr_sql "${EXPECTED_TABLES[@]}")) AS t WHERE to_regclass('public.'||t) IS NULL")"
[[ -z "$MISSING_T" ]] || die 5 "tables missing after migration: $(echo "$MISSING_T" | paste -sd' ')"
MISSING_I="$(dbq "SELECT i FROM unnest($(arr_sql "${EXPECTED_INDEXES[@]}")) AS i WHERE NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname=i)")"
[[ -z "$MISSING_I" ]] || die 5 "indexes missing after migration: $(echo "$MISSING_I" | paste -sd' ')"
dbq "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1" | sort > "$BACKUP_DIR/tables-after.txt"
LOST="$(comm -23 "$BACKUP_DIR/tables-before.txt" "$BACKUP_DIR/tables-after.txt")"
[[ -z "$LOST" ]] || die 5 "pre-existing tables disappeared: $LOST"
log "migration verified: ${#EXPECTED_TABLES[@]} tables, ${#EXPECTED_INDEXES[@]} key indexes, all pre-existing tables intact"

# ------------------------------------------------------------------ 5. dependencies
log "--- dependencies ---"
if [[ "$HAS_PG" != "1" ]]; then
  backup_file package.json; [[ -f package-lock.json ]] && backup_file package-lock.json
  FILES_CHANGED=1
  if [[ -f package-lock.json ]]; then
    command -v npm >/dev/null 2>&1 || die 2 "package-lock.json exists and npm is missing: cannot add 'pg' consistently"
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund "pg@^8.11.3" >/dev/null || die 2 "failed to add pg"
  else
    node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("package.json","utf8"));p.dependencies=p.dependencies||{};p.dependencies.pg="^8.11.3";fs.writeFileSync("package.json",JSON.stringify(p,null,2)+"\n");'
  fi
  log "added dependency: pg"
else
  log "pg already a dependency"
fi

# ------------------------------------------------------------------ 6. application code
log "--- application code ---"

install_file src/lib/redact.js <<'AIG_REDACT_EOF'
'use strict';
// Redaction / sanitisation helpers used before anything is persisted or logged.
const SENSITIVE_KEY = /^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-goog-api-key|api[-_]?key|apikey|secret|password|passwd|pwd|access[-_]?token|refresh[-_]?token|id[-_]?token|session[-_]?token|auth[-_]?token|bearer|private[-_]?key|client[-_]?secret)$|(_secret|_password|_api_key|-api-key)$/i;
const SECRET_PATTERNS = [
  [/Bearer\s+[A-Za-z0-9._~+\/=-]{8,}/gi, 'Bearer [REDACTED]'],
  [/\bgsk_[A-Za-z0-9]{16,}/g, '[REDACTED_KEY]'],
  [/\bAIza[0-9A-Za-z_-]{20,}/g, '[REDACTED_KEY]'],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, '[REDACTED_KEY]'],
  [/\bgh[pousr]_[A-Za-z0-9]{20,}/g, '[REDACTED_KEY]'],
  [/\b(postgres(?:ql)?|redis|rediss|mongodb|amqp):\/\/[^\s"'@]+@/gi, '$1://[REDACTED]@'],
];
const DATA_URL = /data:([a-z0-9.+\/-]+);base64,([A-Za-z0-9+\/=\s]{64,})/gi;
const MAX_STR = parseInt(process.env.AIG_MAX_TEXT_BYTES || '262144', 10);

function isSensitiveKey(k) { return SENSITIVE_KEY.test(String(k)); }

function cleanString(s) {
  let out = String(s).replace(/\u0000/g, '');
  out = out.replace(DATA_URL, (_m, mime, b64) => `[data:${mime};base64 omitted len=${b64.length}]`);
  for (const [re, rep] of SECRET_PATTERNS) out = out.replace(re, rep);
  return out;
}

function truncateText(s, max = MAX_STR) {
  const str = cleanString(s);
  if (Buffer.byteLength(str, 'utf8') <= max) return { text: str, truncated: false };
  return { text: str.slice(0, max) + '…[truncated]', truncated: true };
}

function redact(v, depth = 0) {
  if (v === null || v === undefined) return null;
  const t = typeof v;
  if (t === 'string') return truncateText(v).text;
  if (t === 'number' || t === 'boolean') return v;
  if (v instanceof Date) return v.toISOString();
  if (Buffer.isBuffer(v)) return `[binary ${v.length} bytes]`;
  if (t === 'function' || t === 'symbol') return null;
  if (depth > 8) return '[depth-limit]';
  if (Array.isArray(v)) return v.slice(0, 200).map((x) => redact(x, depth + 1));
  if (t === 'object') {
    const out = {};
    for (const k of Object.keys(v).slice(0, 200)) {
      out[k] = isSensitiveKey(k) ? '[REDACTED]' : redact(v[k], depth + 1);
    }
    return out;
  }
  return null;
}

// Returns a credential-free, query-free reference for http(s) URLs.
function sanitizeUrl(u) {
  try {
    const x = new URL(String(u));
    if (x.protocol !== 'http:' && x.protocol !== 'https:') return { ref: null, hadQuery: false };
    return { ref: `${x.protocol}//${x.host}${x.pathname}`.slice(0, 500), hadQuery: !!(x.search || x.username || x.password) };
  } catch (_) { return { ref: null, hadQuery: false }; }
}

function safeLog(s) { return cleanString(String(s)).replace(/[\r\n\t]+/g, ' ').slice(0, 500); }

module.exports = { redact, cleanString, truncateText, sanitizeUrl, safeLog, isSensitiveKey };
AIG_REDACT_EOF

install_file src/lib/keyPool.js <<'AIG_KEYPOOL_EOF'
'use strict';
// Per-provider API key pool: PROVIDER_API_KEY_1..N (falls back to PROVIDER_API_KEY, PROVIDER_API_KEYS=a,b,c).
// Cooldowns are scoped per (key, model) because provider limits are enforced per model.
const pools = {};
const fallbackKeys = {};

function build(provider) {
  const prefix = `${provider.toUpperCase()}_API_KEY`;
  const keys = [];
  for (let i = 1; i <= 50; i++) {
    const k = process.env[`${prefix}_${i}`];
    if (k) keys.push({ id: i, key: k.trim(), deadUntil: 0, cooldowns: {} });
  }
  if (!keys.length && process.env[`${prefix}S`]) {
    process.env[`${prefix}S`].split(',').map((s) => s.trim()).filter(Boolean).forEach((k, idx) => keys.push({ id: idx + 1, key: k, deadUntil: 0, cooldowns: {} }));
  }
  if (!keys.length && process.env[prefix]) keys.push({ id: 1, key: process.env[prefix].trim(), deadUntil: 0, cooldowns: {} });
  if (!keys.length && fallbackKeys[provider]) keys.push({ id: 1, key: fallbackKeys[provider], deadUntil: 0, cooldowns: {} });
  return { keys, cursor: 0 };
}

function getPool(provider) {
  if (!pools[provider]) pools[provider] = build(provider);
  return pools[provider];
}

// Lets a provider seed a key from its existing config when no env pool is defined.
function setFallbackKey(provider, key) {
  if (!key) return;
  fallbackKeys[provider] = key;
  if (pools[provider] && pools[provider].keys.length === 0) delete pools[provider];
}

function availableKeys(provider, model) {
  const { keys, cursor } = getPool(provider);
  const now = Date.now();
  return keys.slice(cursor).concat(keys.slice(0, cursor))
    .filter((k) => k.deadUntil <= now && (k.cooldowns[model || '*'] || 0) <= now);
}

function markLimited(provider, entry, model, retryAfterSec, fallbackMs = 60000) {
  const pool = getPool(provider);
  const ms = retryAfterSec > 0 ? Math.min(retryAfterSec * 1000, 24 * 3600 * 1000) : fallbackMs;
  entry.cooldowns[model || '*'] = Date.now() + ms;
  pool.cursor = (pool.keys.indexOf(entry) + 1) % pool.keys.length;
}

function markDead(provider, entry, ms = 3600 * 1000) { entry.deadUntil = Date.now() + ms; }
function markGood(provider, entry) { const p = getPool(provider); p.cursor = Math.max(0, p.keys.indexOf(entry)); }

function nextAvailableInMs(provider, model) {
  const { keys } = getPool(provider);
  const now = Date.now();
  let best = Infinity;
  for (const k of keys) best = Math.min(best, Math.max(k.deadUntil, k.cooldowns[model || '*'] || 0) - now);
  return Number.isFinite(best) ? Math.max(0, best) : 0;
}

// Never expose the key itself; only a stable label for telemetry.
function keyRef(provider, entry) { return `${provider}#${entry.id}`; }
function count(provider) { return getPool(provider).keys.length; }

module.exports = { availableKeys, markLimited, markDead, markGood, nextAvailableInMs, keyRef, count, setFallbackKey };
AIG_KEYPOOL_EOF

install_file src/lib/aiMetrics.js <<'AIG_METRICS_EOF'
'use strict';
// Extends (does not replace) existing Prometheus metrics: registers on the app's own Registry from ./metrics
// when it exports one, otherwise on the prom-client default registry. Low-cardinality labels only; never request IDs.
let client = null;
try { client = require('prom-client'); } catch (_) { client = null; }
const M = {};

function registry() {
  try {
    const m = require('./metrics');
    const r = m && (m.register || m.registry);
    if (r && typeof r.getSingleMetric === 'function') return r;
  } catch (_) { /* fall through */ }
  return client ? client.register : null;
}

function get(kind, opts) {
  const reg = registry();
  const existing = reg.getSingleMetric(opts.name);
  return existing || new client[kind]({ ...opts, registers: [reg] });
}

function init() {
  if (M.ready) return true;
  if (!client || !registry()) return false;
  try {
    M.requests = get('Counter', { name: 'aig_ai_requests_total', help: 'External AI provider calls', labelNames: ['provider', 'model', 'status', 'request_type'] });
    M.duration = get('Histogram', { name: 'aig_ai_request_duration_seconds', help: 'External AI call latency', labelNames: ['provider', 'model'], buckets: [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 40] });
    M.tokens = get('Counter', { name: 'aig_ai_tokens_total', help: 'Tokens reported by providers', labelNames: ['provider', 'model', 'type'] });
    M.fallbacks = get('Counter', { name: 'aig_ai_fallbacks_total', help: 'Provider/model switches', labelNames: ['from_provider', 'to_provider', 'reason'] });
    M.rateLimited = get('Counter', { name: 'aig_ai_rate_limited_total', help: 'HTTP 429 responses', labelNames: ['provider', 'model'] });
    M.timeouts = get('Counter', { name: 'aig_ai_timeouts_total', help: 'Provider timeouts', labelNames: ['provider', 'model'] });
    M.vision = get('Counter', { name: 'aig_ai_vision_requests_total', help: 'Requests carrying images', labelNames: ['provider', 'model'] });
    M.images = get('Counter', { name: 'aig_ai_image_generations_total', help: 'Generated images', labelNames: ['provider', 'model', 'status'] });
    M.cache = get('Counter', { name: 'aig_ai_cache_events_total', help: 'Provider cache hits/misses', labelNames: ['provider', 'model', 'result'] });
    M.ready = true;
  } catch (_) { M.ready = false; }
  return !!M.ready;
}

const L = (s) => String(s == null ? 'unknown' : s).slice(0, 64);

function record(s) {
  try {
    if (!init()) return;
    for (const a of s.attempts) {
      const p = L(a.provider), m = L(a.model);
      M.requests.inc({ provider: p, model: m, status: a.success ? 'success' : 'failure', request_type: L(s.requestType) });
      if (a.duration_ms != null) M.duration.observe({ provider: p, model: m }, a.duration_ms / 1000);
      if (a.input_tokens) M.tokens.inc({ provider: p, model: m, type: 'input' }, a.input_tokens);
      if (a.output_tokens) M.tokens.inc({ provider: p, model: m, type: 'output' }, a.output_tokens);
      if (a.cached_tokens) M.tokens.inc({ provider: p, model: m, type: 'cached' }, a.cached_tokens);
      if (a.http_status === 429) M.rateLimited.inc({ provider: p, model: m });
      if (a.is_timeout) M.timeouts.inc({ provider: p, model: m });
      if (a.cache_hit === true) M.cache.inc({ provider: p, model: m, result: 'hit' });
      if (a.cache_hit === false) M.cache.inc({ provider: p, model: m, result: 'miss' });
      if (s.imageCount > 0) M.vision.inc({ provider: p, model: m });
    }
    for (const f of s.fallbacks) M.fallbacks.inc({ from_provider: L(f.from_provider), to_provider: L(f.to_provider), reason: L(f.reason) });
    for (const g of s.generated) M.images.inc({ provider: L(g.provider), model: L(g.model), status: g.success ? 'success' : 'failure' });
  } catch (_) { /* metrics must never break requests */ }
}

module.exports = { record };
AIG_METRICS_EOF

install_file src/lib/telemetry.js <<'AIG_TELEMETRY_EOF'
'use strict';
// AIG_TELEMETRY_V1
// Fail-open, asynchronous, batched persistence of AI interactions into PostgreSQL (aig_* tables).
// Reuses the application's existing pool (./db). Nothing here may throw into the request path.
// Calls that share a request_id (e.g. a router trying groq then gemini) are chained: attempts are
// renumbered, the request row is updated and cross-provider fallbacks are recorded.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { redact, cleanString, truncateText, sanitizeUrl, safeLog, isSensitiveKey } = require('./redact');

let PgPool = null;
try { PgPool = require('pg').Pool; } catch (_) { PgPool = null; }
let logger = null;
try { logger = require('./logger'); } catch (_) { logger = null; }

const ENABLED = String(process.env.AIG_TELEMETRY_ENABLED || 'true').toLowerCase() !== 'false';
const STORE_PAYLOADS = String(process.env.AIG_STORE_PAYLOADS || 'true').toLowerCase() !== 'false';
const MAX_QUEUE = parseInt(process.env.AIG_TELEMETRY_MAX_QUEUE || '2000', 10);
const FLUSH_MS = parseInt(process.env.AIG_TELEMETRY_FLUSH_MS || '1000', 10);
const BATCH_SIZE = parseInt(process.env.AIG_TELEMETRY_BATCH || '25', 10);
const REG_TTL_MS = 60000;
const IMAGE_STORE_DIR = process.env.AIG_IMAGE_STORE_DIR || '';
const IMAGE_MAX_BYTES = parseInt(process.env.AIG_IMAGE_MAX_BYTES || String(20 * 1024 * 1024), 10);

const JSONB_COLS = new Set(['tools', 'response_format', 'request_metadata', 'normalized_request', 'content', 'usage', 'response_headers',
  'provider_metadata', 'response_metadata', 'believed_limits', 'raw_headers', 'routing_decision', 'sanitized_payload', 'metadata',
  'ocr_metadata', 'vision_metadata', 'parameters', 'evaluation_metadata', 'tags', 'config', 'rate_limits']);

let pool = null;
let queue = [];
let dropped = 0;
let timer = null;
let flushing = false;
let downUntil = 0;
const lastWarn = {};
const registryCache = new Map();

function warnOnce(key, msg) {
  const now = Date.now();
  if (lastWarn[key] && now - lastWarn[key] < 30000) return;
  lastWarn[key] = now;
  try {
    if (logger && typeof logger.warn === 'function') logger.warn({ operation: 'aig_telemetry', message: safeLog(msg) });
    else console.warn(`[telemetry] ${safeLog(msg)}`);
  } catch (_) { /* ignore */ }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms))]);
const isUuid = (v) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const str = (v, n = 200) => (v == null ? null : cleanString(String(v)).slice(0, n));
const toInt = (v) => { const n = typeof v === 'string' ? parseInt(v, 10) : v; return Number.isFinite(n) ? Math.trunc(n) : null; };
const toNum = (v) => { const n = typeof v === 'string' ? parseFloat(v) : v; return Number.isFinite(n) ? n : null; };
const estimateTokens = (chars) => Math.ceil((chars || 0) / 4);

function parseDurationSec(v) {
  if (v == null) return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const s = String(v).trim();
  if (/^\d+(\.\d+)?$/.test(s)) return parseFloat(s);
  const re = /(\d+(?:\.\d+)?)(ms|h|m|s)/g;
  let m, total = 0, hit = false;
  while ((m = re.exec(s))) {
    hit = true;
    const n = parseFloat(m[1]);
    total += m[2] === 'h' ? n * 3600 : m[2] === 'm' ? n * 60 : m[2] === 's' ? n : n / 1000;
  }
  return hit ? total : null;
}

// ---------------------------------------------------------------- pool / registry
function getPool() {
  if (!ENABLED) return null;
  if (pool) return pool;
  try { const db = require('./db'); if (db && db.pool && typeof db.pool.connect === 'function') { pool = db.pool; return pool; } } catch (_) { /* fall back */ }
  if (!PgPool) return null;
  const e = process.env;
  const url = e.AIG_DATABASE_URL || e.DATABASE_URL;
  const cfg = url ? { connectionString: url } : { host: e.POSTGRES_HOST || 'postgres', port: parseInt(e.POSTGRES_PORT || '5432', 10),
    database: e.POSTGRES_DB || 'ai_gateway_routing', user: e.POSTGRES_USER || 'ai_gateway', password: e.POSTGRES_PASSWORD || '' };
  pool = new PgPool({ ...cfg, max: 3, connectionTimeoutMillis: 3000, idleTimeoutMillis: 30000, application_name: 'ai-gateway-telemetry' });
  pool.on('error', (err) => warnOnce('poolerr', `pool error: ${err.message}`));
  return pool;
}

function noteDbError(err) { downUntil = Date.now() + 30000; warnOnce('db', `database unavailable: ${err && err.message}`); }

function peekModel(provider, model) {
  const e = registryCache.get(provider);
  return e && e.map ? e.map.get(model) || null : null;
}

async function loadRegistry(provider) {
  const e = registryCache.get(provider);
  if (e && Date.now() - e.at < REG_TTL_MS) return e.map;
  const p = getPool();
  const stale = (e && e.map) || new Map();
  if (!p || Date.now() < downUntil) return stale;
  try {
    const r = await withTimeout(p.query('SELECT * FROM aig_models WHERE provider = $1', [provider]), 1500);
    const map = new Map(r.rows.map((x) => [x.model_id, x]));
    registryCache.set(provider, { at: Date.now(), map });
    return map;
  } catch (err) {
    registryCache.set(provider, { at: Date.now() - REG_TTL_MS + 5000, map: stale });
    if (!/timeout/.test(err.message)) noteDbError(err);
    return stale;
  }
}

// ---------------------------------------------------------------- payload helpers
function headersToObj(h) {
  const out = {};
  if (!h) return out;
  const keep = /^(retry-after|x-ratelimit-|x-request-id|request-id|x-groq|content-type|date|server|via|cf-ray|x-goog-|x-envoy-upstream|openai-)/i;
  const put = (v, k) => { const kk = String(k).toLowerCase(); if (keep.test(kk) && !isSensitiveKey(kk)) out[kk] = cleanString(String(v)).slice(0, 500); };
  if (typeof h.forEach === 'function' && typeof h.get === 'function') h.forEach(put);
  else if (typeof h === 'object') for (const k of Object.keys(h)) put(h[k], k);
  return out;
}

function normalizeUsage(u) {
  if (!u || typeof u !== 'object') return { input: null, output: null, total: null, cached: null, reasoning: null, tool: null };
  const pick = (...vals) => { for (const v of vals) if (typeof v === 'number' && Number.isFinite(v)) return v; return null; };
  const input = pick(u.prompt_tokens, u.input_tokens, u.promptTokenCount);
  const output = pick(u.completion_tokens, u.output_tokens, u.candidatesTokenCount);
  const total = pick(u.total_tokens, u.totalTokenCount);
  const cached = pick(u.prompt_tokens_details && u.prompt_tokens_details.cached_tokens, u.input_tokens_details && u.input_tokens_details.cached_tokens, u.cached_tokens, u.cachedContentTokenCount);
  const reasoning = pick(u.completion_tokens_details && u.completion_tokens_details.reasoning_tokens, u.reasoning_tokens, u.thoughtsTokenCount);
  const tool = pick(u.toolUsePromptTokenCount, u.tool_use_tokens);
  return { input, output, total: total !== null ? total : (input !== null && output !== null ? input + output : null), cached, reasoning, tool };
}

function imageDims(b) {
  try {
    if (b.length > 24 && b[0] === 0x89 && b[1] === 0x50) return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
    if (b.length > 10 && b.slice(0, 3).toString('latin1') === 'GIF') return { width: b.readUInt16LE(6), height: b.readUInt16LE(8) };
    if (b[0] === 0xff && b[1] === 0xd8) {
      let o = 2;
      while (o + 9 < b.length) {
        if (b[o] !== 0xff) { o++; continue; }
        const mk = b[o + 1];
        if (mk >= 0xc0 && mk <= 0xcf && mk !== 0xc4 && mk !== 0xc8 && mk !== 0xcc) return { height: b.readUInt16BE(o + 5), width: b.readUInt16BE(o + 7) };
        o += 2 + b.readUInt16BE(o + 2);
      }
    }
  } catch (_) { /* ignore */ }
  return {};
}
function sniffMime(b) {
  if (b[0] === 0x89 && b[1] === 0x50) return 'image/png';
  if (b[0] === 0xff && b[1] === 0xd8) return 'image/jpeg';
  if (b.slice(0, 3).toString('latin1') === 'GIF') return 'image/gif';
  if (b.slice(0, 4).toString('latin1') === 'RIFF' && b.slice(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
  return null;
}

function describeImage(part, index) {
  let url = null, mime = null, b64 = null, source = null;
  const extra = {};
  const dataMatch = (s) => /^data:([^;,]+)?(;base64)?,([\s\S]*)$/.exec(s);
  if (part.type === 'image_url') {
    url = typeof part.image_url === 'string' ? part.image_url : part.image_url && part.image_url.url;
    if (part.image_url && part.image_url.detail) extra.detail = part.image_url.detail;
  } else if (part.type === 'input_image' || part.type === 'image') {
    url = part.image_url || (part.source && part.source.url) || null;
    if (part.source && part.source.data) { b64 = part.source.data; mime = part.source.media_type; source = 'base64'; }
  } else if (part.inlineData || part.inline_data) {
    const d = part.inlineData || part.inline_data; b64 = d.data; mime = d.mimeType || d.mime_type; source = 'base64';
  } else if (part.fileData || part.file_data) {
    const d = part.fileData || part.file_data; url = d.fileUri || d.file_uri; mime = d.mimeType || d.mime_type; source = 'file_ref';
  } else return null;

  if (typeof url === 'string') {
    const m = dataMatch(url);
    if (m) { b64 = m[3]; mime = m[1] || mime; source = 'base64'; url = null; }
  }
  const rec = { image_index: index, source_type: source || (url ? 'url' : 'reference'), mime_type: mime || null, size_bytes: null, url_ref: null,
    storage_ref: null, content_hash: null, width: null, height: null, vision_metadata: extra };
  if (b64) {
    const buf = Buffer.from(String(b64), 'base64');
    rec.size_bytes = buf.length; rec.content_hash = crypto.createHash('sha256').update(buf).digest('hex');
    Object.assign(rec, imageDims(buf)); rec.mime_type = rec.mime_type || sniffMime(buf);
  } else if (url) {
    const s = sanitizeUrl(url);
    rec.url_ref = s.ref; rec.vision_metadata.url_had_query_or_credentials = s.hadQuery;
    if (s.ref) rec.vision_metadata.url_ref_hash = crypto.createHash('sha256').update(s.ref).digest('hex');
  }
  return rec;
}

function hasImages(messages) {
  if (!Array.isArray(messages)) return false;
  return messages.some((m) => m && Array.isArray(m.content) && m.content.some((p) => p && (/image/.test(p.type || '') || p.inlineData || p.inline_data || p.fileData || p.file_data)));
}

// Returns storable message rows (image bytes never included) plus image descriptors.
function processMessages(messages) {
  const rows = [], images = [];
  let anyTruncated = false, chars = 0;
  (Array.isArray(messages) ? messages : []).forEach((m, seq) => {
    if (!m || typeof m !== 'object') return;
    let text = '', truncated = false, hasImg = false, content;
    if (typeof m.content === 'string') {
      chars += m.content.length;
      const t = truncateText(m.content); text = t.text; truncated = t.truncated; content = t.text;
    } else if (Array.isArray(m.content)) {
      content = m.content.slice(0, 100).map((p) => {
        if (!p || typeof p !== 'object') return redact(p);
        const img = images.length < 32 ? describeImage(p, images.length) : null;
        if (img) { hasImg = true; images.push(img); return { type: 'image', image_index: img.image_index, mime_type: img.mime_type, size_bytes: img.size_bytes, content_hash: img.content_hash, url_ref: img.url_ref }; }
        if (typeof p.text === 'string') { chars += p.text.length; const t = truncateText(p.text); truncated = truncated || t.truncated; text += (text ? '\n' : '') + t.text; return { ...redact({ ...p, text: undefined }), text: t.text }; }
        return redact(p);
      });
    } else content = redact(m.content);
    anyTruncated = anyTruncated || truncated;
    const row = { seq, role: str(m.role, 50), name: str(m.name, 100), content: STORE_PAYLOADS ? content : null, content_text: STORE_PAYLOADS ? text : null, has_images: hasImg, truncated };
    if (m.tool_calls && STORE_PAYLOADS) row.content = { content, tool_calls: redact(m.tool_calls) };
    if (m.tool_call_id && STORE_PAYLOADS) row.content = { content: row.content, tool_call_id: str(m.tool_call_id) };
    rows.push(row);
  });
  return { rows, images, truncated: anyTruncated, chars };
}

function classify(e, status) {
  const code = e ? String(e.code || e.name || '') : '';
  const msg = e ? String(e.message || '') : '';
  const isTimeout = !!(e && (e.timeout || /timeout|ETIMEDOUT/i.test(code + msg)));
  const isRate = status === 429 || /RATE_LIMIT/i.test(code);
  const isContext = /CONTEXT/i.test(code) || (status === 413) || /context (length|window)|too many tokens|maximum context/i.test(msg);
  const isValidation = !isRate && !isContext && (status === 400 || status === 422 || /VALIDATION|UNSUPPORTED_MODALITY|MODEL_NOT_FOUND/i.test(code));
  const retryable = isRate || isTimeout || (status && status >= 500) || /NETWORK|UNAVAILABLE|MALFORMED/i.test(code);
  return { isTimeout, isRate, isContext, isValidation, retryable: !!retryable };
}

function providerErrorFields(e) {
  let code = null, message = null, payload = null;
  if (e && e.bodyText) {
    try {
      const j = JSON.parse(e.bodyText);
      const er = j && (j.error || j);
      code = er && (er.code || er.status || er.type) ? String(er.code || er.status || er.type).slice(0, 200) : null;
      message = er && er.message ? String(er.message) : null;
      payload = redact(j);
    } catch (_) { payload = { raw: truncateText(String(e.bodyText), 2000).text }; }
  }
  return { code, message: message ? truncateText(message, 2000).text : null, payload };
}

// ---------------------------------------------------------------- queue / flush
function schedule() {
  if (timer) return;
  timer = setTimeout(flushLoop, FLUSH_MS);
  if (timer.unref) timer.unref();
}
function enqueue(item) {
  if (!ENABLED) return;
  if (queue.length >= MAX_QUEUE) { queue.shift(); dropped++; warnOnce('drop', `queue full, dropped ${dropped} records so far`); }
  queue.push(item);
  if (queue.length >= BATCH_SIZE) setImmediate(flushLoop); else schedule();
}

async function insertRow(c, table, row, suffix = '') {
  const cols = Object.keys(row).filter((k) => row[k] !== undefined);
  const vals = cols.map((k) => {
    const v = row[k];
    if (v === null) return null;
    if (JSONB_COLS.has(k)) return JSON.stringify(v);
    if (v instanceof Date) return v.toISOString();
    return v;
  });
  await c.query(`INSERT INTO ${table} (${cols.join(',')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(',')}) ${suffix}`, vals);
}

async function writeRecord(c, rec) {
  if (rec.kind === 'config') { await insertRow(c, 'aig_provider_config_snapshots', rec.row); return; }
  if (rec.kind === 'dataset') { await insertRow(c, 'aig_dataset_items', rec.row); return; }

  const id = rec.request.request_id;
  const prior = await c.query('SELECT (SELECT max(attempt_number) FROM aig_attempts WHERE request_id = $1) AS n, EXISTS (SELECT 1 FROM aig_requests WHERE request_id = $1) AS e', [id]);
  const offset = prior.rows[0].n || 0;
  const existed = !!prior.rows[0].e;
  let cross = false;
  const attempts = rec.attempts.map((a) => ({ ...a, attempt_number: a.attempt_number + offset }));
  const fallbacks = rec.fallbacks.map((f) => ({ ...f, attempt_number: f.attempt_number + offset, fallback_attempt_number: f.fallback_attempt_number + offset }));

  if (offset > 0 && attempts.length) {
    const last = await c.query('SELECT provider, model, success, error_class, http_status, retry_after_sec, ended_at FROM aig_attempts WHERE request_id = $1 AND attempt_number = $2 LIMIT 1', [id, offset]);
    const p = last.rows[0], first = attempts[0];
    if (p && (p.provider !== first.provider || p.model !== first.model)) {
      cross = true;
      first.is_fallback = true; first.fallback_reason = p.error_class || 'unknown';
      fallbacks.push({ request_id: id, attempt_number: offset, original_provider: rec.request.requested_provider, original_model: rec.request.requested_model, failure_reason: p.error_class,
        http_status: p.http_status, retry_after_sec: p.retry_after_sec, fallback_provider: first.provider, fallback_model: first.model, fallback_attempt_number: first.attempt_number,
        final_provider: rec.request.final_provider, final_model: rec.request.final_model, total_fallback_count: 0,
        routing_decision: { from: `${p.provider}/${p.model}`, to: `${first.provider}/${first.model}`, trigger: p.error_class, chained_across_calls: true }, occurred_at: first.started_at });
    }
  }
  fallbacks.forEach((f) => { f.final_provider = rec.request.final_provider; f.final_model = rec.request.final_model; f.total_fallback_count = (rec.request.fallback_count || 0) + (cross ? 1 : 0); });

  const r = rec.request;
  const suffix = `ON CONFLICT (request_id) DO UPDATE SET
    final_provider = EXCLUDED.final_provider, final_model = EXCLUDED.final_model, success = EXCLUDED.success, http_status = EXCLUDED.http_status,
    retry_count = aig_requests.retry_count + EXCLUDED.retry_count + 1,
    fallback_count = aig_requests.fallback_count + EXCLUDED.fallback_count + ${cross ? 1 : 0},
    fallback_used = aig_requests.fallback_used OR EXCLUDED.fallback_used OR ${cross ? 'TRUE' : 'FALSE'},
    fallback_reason = COALESCE(aig_requests.fallback_reason, EXCLUDED.fallback_reason),
    request_type = CASE WHEN EXCLUDED.request_type = 'chat' THEN aig_requests.request_type ELSE EXCLUDED.request_type END,
    input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens, total_tokens = EXCLUDED.total_tokens, cached_tokens = EXCLUDED.cached_tokens,
    error_class = EXCLUDED.error_class, error_message = EXCLUDED.error_message, completed_at = EXCLUDED.completed_at,
    duration_ms = (EXTRACT(EPOCH FROM (EXCLUDED.completed_at - aig_requests.started_at)) * 1000)::int`;
  await insertRow(c, 'aig_requests', r, suffix);

  if (!existed) {
    for (const m of rec.messages) await insertRow(c, 'aig_messages', m);
    for (const v of rec.vision) await insertRow(c, 'aig_vision_inputs', v);
  }
  for (const a of attempts) await insertRow(c, 'aig_attempts', a);
  for (const x of rec.responses) await insertRow(c, 'aig_responses', x);
  for (const x of rec.rate) await insertRow(c, 'aig_rate_limit_observations', x);
  for (const x of fallbacks) await insertRow(c, 'aig_fallback_events', x);
  for (const x of rec.errors) await insertRow(c, 'aig_errors', x);
  for (const x of rec.cache) await insertRow(c, 'aig_cache_events', x);
  for (const x of rec.generated) await insertRow(c, 'aig_generated_images', x);
  for (const x of rec.dataset || []) await insertRow(c, 'aig_dataset_items', x);
  for (const a of attempts) {
    if (a.success && a.model) {
      await c.query('INSERT INTO aig_models (provider, model_id, last_verified_at) VALUES ($1,$2,now()) ON CONFLICT (provider, model_id) DO UPDATE SET last_verified_at = now(), updated_at = now()', [a.provider, a.model]);
    }
  }
}

async function flushRecords(records, opts = {}) {
  const p = getPool();
  if (!p) return { ok: false, connectionError: true, written: 0, errors: ['no database pool'] };
  let client;
  try { client = await p.connect(); } catch (e) { noteDbError(e); return { ok: false, connectionError: true, written: 0, errors: [e.message] }; }
  const errors = []; let written = 0, connectionError = false;
  try {
    await client.query('BEGIN');
    for (const rec of records) {
      await client.query('SAVEPOINT aig_rec');
      try { await writeRecord(client, rec); await client.query('RELEASE SAVEPOINT aig_rec'); written++; }
      catch (e) { errors.push(`${rec.kind}: ${e.message}`); await client.query('ROLLBACK TO SAVEPOINT aig_rec'); }
    }
    await client.query(opts.rollback ? 'ROLLBACK' : 'COMMIT');
  } catch (e) {
    connectionError = true; errors.push(e.message);
    try { await client.query('ROLLBACK'); } catch (_) { /* ignore */ }
    noteDbError(e);
  } finally { client.release(); }
  if (errors.length && !opts.rollback) warnOnce('flush', `persist errors: ${errors.slice(0, 2).join(' | ')}`);
  return { ok: errors.length === 0, connectionError, written, errors };
}

async function flushLoop() {
  if (timer) { clearTimeout(timer); timer = null; }
  if (flushing || !queue.length) return;
  const p = getPool();
  if (!p) { queue.length = 0; return; }
  if (Date.now() < downUntil) { schedule(); return; }
  flushing = true;
  const batch = queue.splice(0, BATCH_SIZE);
  try {
    const res = await flushRecords(batch);
    if (res.connectionError) { queue.unshift(...batch); if (queue.length > MAX_QUEUE) { dropped += queue.length - MAX_QUEUE; queue.length = MAX_QUEUE; } }
  } catch (e) { warnOnce('flushloop', e.message); }
  finally { flushing = false; if (queue.length) schedule(); }
}

async function flush(timeoutMs = 5000) {
  const end = Date.now() + timeoutMs;
  while ((queue.length || flushing) && Date.now() < end) { if (!flushing) await flushLoop(); else await sleep(50); }
}
process.on('beforeExit', () => { if (queue.length) flushLoop(); });

// ---------------------------------------------------------------- generated image handling
function buildGeneratedImage(requestId, g) {
  const imageId = crypto.randomUUID();
  let buf = null;
  if (g.buffer && Buffer.isBuffer(g.buffer)) buf = g.buffer;
  else if (typeof g.b64 === 'string') { const m = /^data:[^,]*,([\s\S]*)$/.exec(g.b64); buf = Buffer.from(m ? m[1] : g.b64, 'base64'); }
  let hash = g.hash || null, size = g.fileSize || null, mime = g.mime || null, width = toInt(g.width), height = toInt(g.height), storageRef = g.storageRef ? str(g.storageRef, 500) : null;
  if (buf && buf.length) {
    hash = crypto.createHash('sha256').update(buf).digest('hex'); size = buf.length; mime = mime || sniffMime(buf);
    const d = imageDims(buf); width = width || d.width || null; height = height || d.height || null;
    if (!storageRef && IMAGE_STORE_DIR && size <= IMAGE_MAX_BYTES) {
      const ext = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' }[mime] || 'bin';
      const now = new Date();
      const rel = path.posix.join(String(now.getUTCFullYear()), String(now.getUTCMonth() + 1).padStart(2, '0'), `${hash}.${ext}`); // hash-derived name: no traversal
      storageRef = `fs:${rel}`;
      const abs = path.join(IMAGE_STORE_DIR, rel);
      fs.promises.mkdir(path.dirname(abs), { recursive: true }).then(() => fs.promises.writeFile(abs, buf, { flag: 'wx' })).catch((e) => { if (e.code !== 'EEXIST') warnOnce('imgstore', `image store failed: ${e.message}`); });
    }
  }
  const u = g.imageUrl ? sanitizeUrl(g.imageUrl) : { ref: null };
  return {
    image_id: imageId, request_id: requestId, provider: str(g.provider, 100), model: str(g.model, 200), generation_id: str(g.generationId, 200),
    image_url: u.ref, storage_ref: storageRef, retrievable: !!(storageRef || u.ref), mime_type: str(mime, 100), width, height,
    file_size_bytes: size, image_hash: hash, prompt: g.prompt != null ? truncateText(String(g.prompt), 20000).text : null,
    negative_prompt: g.negativePrompt != null ? truncateText(String(g.negativePrompt), 20000).text : null, seed: toInt(g.seed),
    parameters: redact(g.parameters || null), provider_metadata: redact(g.providerMetadata || null), success: g.success !== false,
    latency_ms: toInt(g.latencyMs), error_message: g.error ? truncateText(String(g.error.message || g.error), 2000).text : null,
    reproducible: g.reproducible != null ? !!g.reproducible : (g.seed != null && !!g.prompt), created_at: new Date(),
  };
}

// ---------------------------------------------------------------- interaction API
function startInteraction(init = {}) {
  const ctx = init.ctx && typeof init.ctx === 'object' ? init.ctx : {};
  const params = init.params || {};
  const requestId = isUuid(ctx.request_id) ? ctx.request_id : isUuid(ctx.requestId) ? ctx.requestId : crypto.randomUUID();
  const st = { attempts: [], responses: [], rate: [], cache: [], errors: [], generated: [], finished: false, requestType: init.requestType || null };
  let pm = { rows: [], images: [], truncated: false, chars: 0 };
  try { pm = processMessages(init.messages); } catch (e) { warnOnce('procmsg', e.message); }
  if (!st.requestType) st.requestType = pm.images.length ? 'vision' : 'chat';
  const startedAt = new Date();
  const t0 = Date.now();

  const api = {
    requestId,
    setRequestType(t) { if (t) st.requestType = String(t).slice(0, 50); },

    addAttempt(a = {}) {
      try {
        const provider = str(a.provider || init.provider || 'unknown', 100);
        const model = a.model ? str(a.model, 200) : null;
        const e = a.error || null;
        const h = headersToObj(a.headers || (e && e.headers));
        const status = toInt(a.httpStatus) || (e ? toInt(e.status) : null);
        const u = normalizeUsage(a.usage);
        const reg = peekModel(provider, model);
        const cls = e ? classify(e, status) : { isTimeout: false, isRate: false, isContext: false, isValidation: false, retryable: false };
        const attemptId = crypto.randomUUID();
        const nowMs = Date.now();
        let estIn = null, estOut = null;
        if (a.success && u.input === null) estIn = estimateTokens(pm.chars);
        if (a.success && u.output === null && a.responseText) estOut = estimateTokens(String(a.responseText).length);
        const retryAfter = e && e.retryAfter != null ? toNum(e.retryAfter) : parseDurationSec(h['retry-after']);
        const attempt = {
          attempt_id: attemptId, request_id: requestId, attempt_number: st.attempts.length + 1, provider, model,
          provider_account_ref: str(a.keyRef, 100), endpoint: str(a.endpoint || init.endpoint, 200),
          started_at: new Date(a.startedAt || nowMs), ended_at: new Date(nowMs), duration_ms: toInt(a.durationMs),
          http_status: status, success: !!a.success, is_fallback: false, fallback_reason: null,
          error_class: e ? str(e.code || e.name || 'Error', 100) : null, is_timeout: cls.isTimeout, retry_after_sec: retryAfter,
          finish_reason: str(a.finishReason, 100), system_fingerprint: str(a.systemFingerprint, 200), provider_request_id: str(a.providerRequestId || h['x-request-id'] || h['x-groq-request-id'], 200),
          input_tokens: u.input, output_tokens: u.output, total_tokens: u.total, cached_tokens: u.cached, reasoning_tokens: u.reasoning, tool_tokens: u.tool,
          estimated_input_tokens: estIn, estimated_output_tokens: estOut, tokens_estimated: estIn !== null || estOut !== null,
          requested_max_tokens: toInt(params.max_tokens),
          documented_context_window: reg ? reg.context_window : null, documented_max_input_tokens: reg ? reg.max_input_tokens : null, documented_max_output_tokens: reg ? reg.max_output_tokens : null,
          remaining_context_tokens: reg && reg.context_window && u.total !== null ? reg.context_window - u.total : null,
          usage: a.usage ? redact(a.usage) : null, response_headers: h, provider_metadata: redact(a.providerMetadata || null),
        };
        st.attempts.push({ ...attempt, cache_hit: u.cached !== null ? u.cached > 0 : null });

        if (Object.keys(h).some((k) => k.startsWith('x-ratelimit-') || k === 'retry-after') || status === 429) {
          const dReq = parseDurationSec(h['x-ratelimit-reset-requests']), dTok = parseDurationSec(h['x-ratelimit-reset-tokens']);
          st.rate.push({
            request_id: requestId, attempt_id: attemptId, provider, model, provider_account_ref: str(a.keyRef, 100), observed_at: new Date(nowMs), http_status: status,
            is_rate_limited: status === 429, retry_after_sec: retryAfter, limit_requests: toInt(h['x-ratelimit-limit-requests']), limit_tokens: toInt(h['x-ratelimit-limit-tokens']),
            remaining_requests: toInt(h['x-ratelimit-remaining-requests']), remaining_tokens: toInt(h['x-ratelimit-remaining-tokens']),
            reset_requests_raw: str(h['x-ratelimit-reset-requests'], 100), reset_tokens_raw: str(h['x-ratelimit-reset-tokens'], 100),
            reset_requests_at: dReq !== null ? new Date(nowMs + dReq * 1000) : null, reset_tokens_at: dTok !== null ? new Date(nowMs + dTok * 1000) : null,
            believed_limits: reg && reg.rate_limits ? reg.rate_limits : null, raw_headers: h,
          });
        }
        if (a.success && (u.cached !== null || a.cacheRequested || a.cacheRef)) {
          st.cache.push({
            request_id: requestId, attempt_id: attemptId, provider, model, cache_type: str(a.cacheType || (provider === 'gemini' ? 'context' : 'prompt'), 50),
            cache_requested: !!a.cacheRequested, cache_hit: u.cached !== null ? u.cached > 0 : null, cached_tokens: u.cached, cache_ref: str(a.cacheRef, 300),
            cache_created_at: a.cacheCreatedAt ? new Date(a.cacheCreatedAt) : null, cache_expires_at: a.cacheExpiresAt ? new Date(a.cacheExpiresAt) : null,
            ttl_seconds: toInt(a.cacheTtlSeconds), metadata: redact(a.cacheMetadata || null),
          });
        }
        if (!a.success) {
          const pf = providerErrorFields(e);
          st.errors.push({
            request_id: requestId, attempt_id: attemptId, provider, model, request_type: st.requestType, error_class: attempt.error_class, http_status: status,
            provider_error_code: pf.code, provider_error_message: pf.message || (e ? truncateText(String(e.message || ''), 2000).text : null), retryable: cls.retryable,
            retry_after_sec: retryAfter, is_timeout: cls.isTimeout, is_context_limit: cls.isContext, is_rate_limit: cls.isRate, is_validation: cls.isValidation,
            fallback_decision: null, final_result: null, stack_trace: e && e.stack ? truncateText(String(e.stack), 4000).text : null, sanitized_payload: pf.payload, occurred_at: new Date(nowMs),
          });
        } else {
          const t = a.responseText != null ? truncateText(typeof a.responseText === 'string' ? a.responseText : JSON.stringify(a.responseText)) : { text: '', truncated: false };
          st.responses.push({
            request_id: requestId, attempt_id: attemptId, provider, model, content_text: STORE_PAYLOADS ? t.text : null,
            content: STORE_PAYLOADS && a.toolCalls ? { tool_calls: redact(a.toolCalls) } : null, finish_reason: attempt.finish_reason, truncated: t.truncated,
            response_metadata: redact({ system_fingerprint: a.systemFingerprint, ...(a.providerMetadata || {}) }),
          });
        }
      } catch (err) { warnOnce('addAttempt', err.message); }
    },

    addGeneratedImage(g = {}) {
      try { st.generated.push(buildGeneratedImage(requestId, { provider: init.provider, model: init.requestedModel, prompt: g.prompt, ...g })); }
      catch (err) { warnOnce('addImage', err.message); }
    },

    finish(f = {}) {
      try {
        if (st.finished) return null;
        st.finished = true;
        const attempts = st.attempts;
        const last = attempts[attempts.length - 1] || null;
        const fallbacks = [];
        for (let i = 1; i < attempts.length; i++) {
          const prev = attempts[i - 1], cur = attempts[i];
          if (prev.provider !== cur.provider || prev.model !== cur.model) {
            cur.is_fallback = true; cur.fallback_reason = prev.error_class || 'unknown';
            fallbacks.push({ request_id: requestId, attempt_number: prev.attempt_number, original_provider: attempts[0].provider, original_model: attempts[0].model,
              failure_reason: prev.error_class, http_status: prev.http_status, retry_after_sec: prev.retry_after_sec, fallback_provider: cur.provider, fallback_model: cur.model,
              fallback_attempt_number: cur.attempt_number, final_provider: null, final_model: null, total_fallback_count: 0,
              routing_decision: { from: `${prev.provider}/${prev.model}`, to: `${cur.provider}/${cur.model}`, trigger: prev.error_class, key_ref: cur.provider_account_ref }, occurred_at: cur.started_at });
          } else if (cur.provider_account_ref !== prev.provider_account_ref) { cur.fallback_reason = 'key_rotation'; }
        }
        const success = !!f.success;
        const okAttempt = success ? [...attempts].reverse().find((a) => a.success) || last : last;
        const finalProvider = f.finalProvider || (okAttempt && okAttempt.provider) || init.provider || null;
        const finalModel = f.finalModel || (okAttempt && okAttempt.model) || null;
        fallbacks.forEach((x) => { x.final_provider = finalProvider; x.final_model = finalModel; x.total_fallback_count = fallbacks.length; });
        st.errors.forEach((x) => {
          const idx = (attempts.find((y) => y.attempt_id === x.attempt_id) || {}).attempt_number || 0;
          x.final_result = success ? 'recovered' : 'failed';
          x.fallback_decision = attempts.some((a) => a.attempt_number > idx) ? 'retried_or_switched' : 'none';
        });
        const err = f.error || (last && !last.success ? { code: last.error_class, message: null } : null);
        const request = {
          request_id: requestId, trace_id: str(ctx.trace_id || ctx.traceId), session_id: str(ctx.session_id || ctx.sessionId), conversation_id: str(ctx.conversation_id || ctx.conversationId),
          parent_request_id: isUuid(ctx.parent_request_id) ? ctx.parent_request_id : null, agent_name: str(ctx.agent_name || ctx.agent), worker: str(ctx.worker),
          task: str(ctx.task || ctx.intent || ctx.capability), request_type: st.requestType, requested_provider: str(init.requestedProvider || init.provider, 100),
          requested_model: str(init.requestedModel, 200), final_provider: str(finalProvider, 100), final_model: str(finalModel, 200), endpoint: str(init.endpoint, 200),
          model_version: null, routing_reason: str(f.routingReason || (fallbacks.length ? `fallback_after:${fallbacks[0].failure_reason}` : 'requested'), 300),
          success, http_status: last ? last.http_status : null, retry_count: Math.max(0, attempts.length - 1), fallback_used: fallbacks.length > 0, fallback_count: fallbacks.length,
          fallback_reason: fallbacks.length ? fallbacks[0].failure_reason : null, temperature: toNum(params.temperature), max_tokens: toInt(params.max_tokens), top_p: toNum(params.top_p),
          seed: toInt(params.seed), tools: params.tools ? redact(params.tools) : null, response_format: params.response_format ? redact(params.response_format) : null,
          request_metadata: ctx.metadata ? redact(ctx.metadata) : null, normalized_request: redact(params),
          input_tokens: okAttempt ? okAttempt.input_tokens : null, output_tokens: okAttempt ? okAttempt.output_tokens : null, total_tokens: okAttempt ? okAttempt.total_tokens : null,
          cached_tokens: okAttempt ? okAttempt.cached_tokens : null, image_count: pm.images.length, input_truncated: pm.truncated,
          error_class: success ? null : str(err && (err.code || err.name), 100), error_message: success ? null : (err && err.message ? truncateText(String(err.message), 2000).text : null),
          started_at: startedAt, completed_at: new Date(), duration_ms: Date.now() - t0,
        };
        const rec = {
          kind: 'interaction', request,
          messages: pm.rows.map((r) => ({ request_id: requestId, ...r })),
          attempts: attempts.map(({ cache_hit, ...rest }) => rest), responses: st.responses, rate: st.rate, fallbacks, errors: st.errors, cache: st.cache,
          vision: pm.images.map((im) => ({ request_id: requestId, provider: finalProvider, model: finalModel, ...im, ocr_metadata: null })), generated: st.generated, dataset: [],
        };
        if (init.dryRun) return rec;
        enqueue(rec);
        try {
          require('./aiMetrics').record({ requestType: st.requestType, imageCount: pm.images.length, attempts, generated: st.generated,
            fallbacks: fallbacks.map((x) => ({ from_provider: x.original_provider, to_provider: x.fallback_provider, reason: x.failure_reason })) });
        } catch (_) { /* ignore */ }
        return null;
      } catch (err) { warnOnce('finish', err.message); return null; }
    },
  };
  return api;
}

function recordProviderConfig(provider, config) {
  try { enqueue({ kind: 'config', row: { provider: str(provider, 100), config: redact(config), taken_at: new Date() } }); } catch (_) { /* ignore */ }
}

// Explicitly mark a stored interaction as a training/evaluation candidate. Scores are stored ONLY when supplied.
function markDatasetCandidate(requestId, opts = {}) {
  try {
    if (!isUuid(requestId)) return;
    enqueue({ kind: 'dataset', row: {
      request_id: requestId, attempt_id: isUuid(opts.attemptId) ? opts.attemptId : null, image_id: isUuid(opts.imageId) ? opts.imageId : null,
      label: str(opts.label, 50), quality: str(opts.quality, 20), human_reviewed: !!opts.humanReviewed, auto_evaluated: !!opts.autoEvaluated,
      quality_score: toNum(opts.qualityScore), evaluation_metadata: redact(opts.evaluationMetadata || null), human_feedback: opts.humanFeedback ? truncateText(String(opts.humanFeedback), 8000).text : null,
      tags: redact(opts.tags || null), dataset_name: str(opts.datasetName, 200), dataset_version: str(opts.datasetVersion, 100),
      inclusion_status: str(opts.inclusionStatus || 'pending', 50), created_by: str(opts.createdBy, 100),
    } });
  } catch (_) { /* ignore */ }
}

// Validates that every record type (incl. request chaining) can be written to the live schema; always rolled back.
async function selfTest() {
  if (!getPool()) return { ok: false, error: 'no database pool (src/lib/db.js / POSTGRES_* env not usable)' };
  const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  const rid = crypto.randomUUID();
  const it = startInteraction({ provider: 'selftest', requestedModel: 'selftest-model', endpoint: '/selftest', ctx: { request_id: rid, task: 'aig_upgrade_selftest', trace_id: 'selftest' }, dryRun: true,
    messages: [{ role: 'system', content: 'sys' }, { role: 'user', content: [{ type: 'text', text: 'describe' }, { type: 'image_url', image_url: { url: `data:image/png;base64,${png}` } }] }],
    params: { temperature: 0.3, max_tokens: 16 } });
  it.addAttempt({ provider: 'selftest', model: 'selftest-model', success: false, httpStatus: 429, keyRef: 'selftest#1', durationMs: 5,
    headers: { 'retry-after': '3', 'x-ratelimit-remaining-tokens': '0', 'x-ratelimit-reset-tokens': '2m59.56s', authorization: 'Bearer should-not-persist' },
    error: { code: 'PROVIDER_RATE_LIMITED', message: 'rate limited', retryAfter: 3, bodyText: '{"error":{"message":"limit","code":"rate_limit_exceeded"}}' } });
  it.addAttempt({ provider: 'selftest', model: 'selftest-fallback', success: true, httpStatus: 200, durationMs: 7, responseText: 'ok', finishReason: 'stop',
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15, prompt_tokens_details: { cached_tokens: 4 } } });
  it.addGeneratedImage({ provider: 'selftest', model: 'img', prompt: 'p', b64: png, parameters: { steps: 1 }, seed: 1, success: true });
  const rec = it.finish({ success: true });
  rec.dataset.push({ request_id: rid, label: 'evaluation_candidate', dataset_name: 'selftest', inclusion_status: 'pending', human_reviewed: false, auto_evaluated: false });

  // second call sharing the same request_id, different provider: exercises chaining (renumbering + cross-call fallback)
  const it2 = startInteraction({ provider: 'selftest2', requestedModel: 'other', endpoint: '/selftest', ctx: { request_id: rid }, dryRun: true, messages: [{ role: 'user', content: 'x' }], params: {} });
  it2.addAttempt({ provider: 'selftest2', model: 'other', success: true, httpStatus: 200, durationMs: 3, responseText: 'ok2', usage: { prompt_tokens: 1, completion_tokens: 1 } });
  const rec2 = it2.finish({ success: true });

  const res = await flushRecords([rec, rec2], { rollback: true });
  return { ok: res.ok && res.written === 2, written: res.written, errors: res.errors, attempts: rec.attempts.length, fallbacks: rec.fallbacks.length,
    vision_rows: rec.vision.length, rate_rows: rec.rate.length, cache_rows: rec.cache.length, image_rows: rec.generated.length, redacted_header_present: !!rec.rate[0].raw_headers.authorization };
}

module.exports = { startInteraction, recordProviderConfig, markDatasetCandidate, loadRegistry, peekModel, flush, selfTest, hasImages, estimateTokens, parseDurationSec,
  stats: () => ({ queued: queue.length, dropped, enabled: ENABLED, dbDownUntil: downUntil }) };
AIG_TELEMETRY_EOF

install_file src/lib/instrument.js <<'AIG_INSTRUMENT_EOF'
'use strict';
// Non-invasive instrumentation wrapper for providers whose source we do not rewrite (gemini, local, image workers...).
// If the caller passes a UUID request_id / requestId in the options, calls to several providers made for the same
// request are chained in the database (attempt numbering + provider-switch audit).
const telemetry = require('./telemetry');

const MSG_KEYS = new Set(['messages', 'message', 'instruction', 'system', 'prompt', 'negative_prompt', 'image', 'images', 'b64_json', 'metadata']);

function normalizeInput(o) {
  if (Array.isArray(o.messages) && o.messages.length) return o.messages;
  const out = [];
  const sys = o.instruction || o.system;
  if (sys) out.push({ role: 'system', content: String(sys) });
  const user = o.message != null ? o.message : o.prompt;
  if (user != null) out.push({ role: 'user', content: typeof user === 'string' ? user : JSON.stringify(user).slice(0, 100000) });
  return out;
}

function pickParams(o) {
  const p = {};
  for (const k of ['temperature', 'max_tokens', 'top_p', 'seed', 'tools', 'response_format']) if (o[k] !== undefined) p[k] = o[k];
  const extra = {};
  let n = 0;
  for (const k of Object.keys(o)) { if (!MSG_KEYS.has(k) && !(k in p) && n++ < 40 && k !== 'model') extra[k] = o[k]; }
  p.extra = extra;
  return p;
}

function extractGenerated(result) {
  const out = [];
  if (!result || typeof result !== 'object') return out;
  let arr = [];
  if (Array.isArray(result.images)) arr = result.images;
  else if (Array.isArray(result.data) && result.data.some((x) => x && (x.url || x.b64_json))) arr = result.data;
  for (const x of arr.slice(0, 16)) {
    if (typeof x === 'string') out.push(/^https?:/.test(x) ? { imageUrl: x } : { b64: x });
    else if (x && typeof x === 'object') out.push({ imageUrl: x.url || x.image_url, b64: x.b64_json || x.b64 || x.base64, storageRef: x.storage_ref || x.path || x.file, mime: x.mime_type || x.mime,
      width: x.width, height: x.height, generationId: x.id || x.generation_id, seed: x.seed, providerMetadata: x.metadata });
  }
  if (!out.length) {
    const url = result.image_url || result.imageUrl || (typeof result.url === 'string' && /image|\.(png|jpe?g|webp|gif)/i.test(result.url) ? result.url : null);
    const b64 = result.b64_json || result.image_base64 || (typeof result.image === 'string' ? result.image : null);
    const file = result.image_path || result.output_path || result.filename;
    if (url || b64 || file) out.push({ imageUrl: url, b64, storageRef: file, seed: result.seed, generationId: result.id || result.prompt_id });
  }
  return out;
}

function wrap(providerName, fn) {
  if (typeof fn !== 'function' || fn.__aigWrapped) return fn;
  const wrapped = async function aigInstrumented(opts) {
    const o = opts && typeof opts === 'object' ? opts : {};
    let t = null;
    try {
      t = telemetry.startInteraction({ provider: providerName, requestedModel: o.model, ctx: o, messages: normalizeInput(o), params: pickParams(o), requestType: o.request_type || o.type });
    } catch (_) { t = null; }
    const started = Date.now();
    try {
      const result = await fn.apply(this, arguments);
      if (t) {
        const rt = result && (result.response !== undefined ? result.response : (result.text !== undefined ? result.text : result.output));
        const usage = result && (result.usage || result.usageMetadata || (result.raw && result.raw.usageMetadata));
        t.addAttempt({ provider: providerName, model: (result && result.model) || o.model || 'unknown', startedAt: started, durationMs: Date.now() - started, httpStatus: 200, success: true,
          usage, responseText: typeof rt === 'string' ? rt : (rt != null ? JSON.stringify(rt).slice(0, 100000) : ''), headers: result && result.headers,
          finishReason: result && (result.finish_reason || result.finishReason), providerMetadata: { result_keys: Object.keys(result || {}).slice(0, 30) } });
        const gens = extractGenerated(result);
        if (gens.length) { t.setRequestType('image_generation'); gens.forEach((g) => t.addGeneratedImage({ ...g, prompt: o.prompt || o.message, negativePrompt: o.negative_prompt, parameters: pickParams(o).extra, latencyMs: Date.now() - started })); }
        t.finish({ success: true });
      }
      return result;
    } catch (err) {
      if (t) {
        t.addAttempt({ provider: providerName, model: o.model || 'unknown', startedAt: started, durationMs: Date.now() - started, success: false, error: err, httpStatus: err && err.status });
        t.finish({ success: false, error: err });
      }
      throw err;
    }
  };
  wrapped.__aigWrapped = true;
  return wrapped;
}

module.exports = { wrap };
AIG_INSTRUMENT_EOF

# --- groq provider: full replacement only when the existing file matches the expected shape (checked above)
install_file src/providers/groq.js <<'AIG_GROQ_EOF'
'use strict';
// AIG_TELEMETRY_V1: Groq provider with key-pool rotation, model fallback and database telemetry.
const fetch = require('node-fetch');
const config = require('../lib/config');
const keyPool = require('../lib/keyPool');
const telemetry = require('../lib/telemetry');

class ProviderError extends Error {
  constructor(code, message, extra) {
    super(message);
    this.code = code;
    if (extra) Object.assign(this, extra);
  }
}

const TIMEOUT_MS = parseInt(process.env.GROQ_TIMEOUT_MS || '20000', 10);
const MAX_TOTAL_MS = parseInt(process.env.AIG_MAX_TOTAL_MS || '60000', 10);
let configSnapshotSent = false;

function envFallbackModels() {
  const fromCfg = (config.providers.groq && config.providers.groq.fallbackModels) || [];
  const fromEnv = (process.env.GROQ_FALLBACK_MODELS || '').split(',').map((s) => s.trim()).filter(Boolean);
  return [...fromCfg, ...fromEnv];
}

// One attempt with one key and one model. Throws ProviderError carrying status/headers/body for telemetry.
async function callGroq(apiKey, requestBody) {
  const gcfg = config.providers.groq;
  let response;
  try {
    response = await fetch(`${gcfg.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(requestBody),
      timeout: TIMEOUT_MS,
    });
  } catch (err) {
    if (err.type === 'request-timeout') throw new ProviderError('UPSTREAM_TIMEOUT', 'Groq request timed out', { timeout: true });
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Groq: ${err.message}`, { stack: err.stack });
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }
    const ra = parseFloat(response.headers.get('retry-after'));
    const extra = { status: response.status, headers: response.headers, bodyText, retryAfter: Number.isFinite(ra) ? ra : 0 };
    if (response.status === 401 || response.status === 403) throw new ProviderError('PROVIDER_AUTH_FAILED', 'Groq rejected the API key', extra);
    if (response.status === 429) throw new ProviderError('PROVIDER_RATE_LIMITED', 'Groq rate limit exceeded', extra);
    if (response.status === 413 || (response.status === 400 && /context (length|window)|too many tokens|maximum context|reduce the length/i.test(bodyText))) {
      throw new ProviderError('CONTEXT_TOO_LARGE', `Request exceeds context/token limits for "${requestBody.model}"`, extra);
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText) && !/image|vision/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Groq does not recognize model "${requestBody.model}"`, extra);
    }
    if (response.status === 400 && /image|vision|multimodal|modalit/i.test(bodyText)) {
      throw new ProviderError('UNSUPPORTED_MODALITY', `Model "${requestBody.model}" rejected image/multimodal input`, extra);
    }
    if (response.status >= 500) throw new ProviderError('PROVIDER_UNAVAILABLE', `Groq returned status ${response.status}`, extra);
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Groq returned status ${response.status}: ${bodyText.slice(0, 300)}`, extra);
  }

  let data;
  try { data = await response.json(); } catch (_) {
    throw new ProviderError('MALFORMED_RESPONSE', 'Groq returned a non-JSON body', { status: response.status, headers: response.headers });
  }
  if (!data || !Array.isArray(data.choices)) {
    throw new ProviderError('MALFORMED_RESPONSE', 'Groq response has no choices', { status: response.status, headers: response.headers });
  }
  return { data, headers: response.headers, status: response.status };
}

async function execute(opts = {}) {
  const { message, model, temperature, instruction, messages: structuredMessages, max_tokens } = opts;
  const gcfg = config.providers.groq;
  keyPool.setFallbackKey('groq', gcfg.apiKey);
  if (keyPool.count('groq') === 0) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'No GROQ_API_KEY / GROQ_API_KEY_[1-N] configured');
  }

  // Structured messages[] take precedence; legacy {message, instruction} is preserved.
  let messages;
  if (Array.isArray(structuredMessages) && structuredMessages.length > 0) {
    messages = structuredMessages.map((m) => ({ ...m, role: m.role || 'user', content: m.content }));
  } else {
    messages = [];
    if (instruction) messages.push({ role: 'system', content: instruction });
    messages.push({ role: 'user', content: message });
  }

  const primary = model || gcfg.defaultModel;
  const baseBody = { messages, temperature: typeof temperature === 'number' ? temperature : 0.3 };
  if (typeof max_tokens === 'number') baseBody.max_tokens = max_tokens;
  for (const k of ['top_p', 'seed', 'stop', 'tools', 'tool_choice', 'response_format']) if (opts[k] !== undefined && opts[k] !== null) baseBody[k] = opts[k];

  const vision = telemetry.hasImages(messages);
  const registry = await telemetry.loadRegistry('groq');
  if (!configSnapshotSent) {
    configSnapshotSent = true;
    telemetry.recordProviderConfig('groq', { base_url: gcfg.baseUrl, default_model: gcfg.defaultModel, fallback_models: envFallbackModels(), key_count: keyPool.count('groq') });
  }

  const estTokens = telemetry.estimateTokens(JSON.stringify(messages).length) + (typeof max_tokens === 'number' ? max_tokens : 0);
  const usable = (m) => {
    const row = registry.get(m);
    if (!row) return true;
    if (row.enabled === false || row.active === false || row.availability === 'unavailable') return false;
    if (vision && row.supports_vision === false) return false;
    if (row.context_window && estTokens > row.context_window) return false;
    return true;
  };
  const dbFallbacks = [...registry.values()].filter((r) => r.fallback_eligible && r.enabled && r.active)
    .sort((a, b) => (a.fallback_priority - b.fallback_priority) || (a.priority - b.priority)).map((r) => r.model_id);
  let candidates = [...new Set([primary, ...envFallbackModels(), ...dbFallbacks])].filter(Boolean).filter(usable);
  if (!candidates.length) candidates = [primary];

  const t = telemetry.startInteraction({
    provider: 'groq', endpoint: '/chat/completions', requestedModel: primary, ctx: opts, messages,
    params: { temperature: baseBody.temperature, max_tokens: baseBody.max_tokens, top_p: baseBody.top_p, seed: baseBody.seed, stop: baseBody.stop, tools: baseBody.tools, response_format: baseBody.response_format },
    requestType: vision ? 'vision' : 'chat',
  });

  const t0 = Date.now();
  let lastError = null;
  let minRetry = 0;

  outer:
  for (const chosenModel of candidates) {
    const keys = keyPool.availableKeys('groq', chosenModel);
    if (!keys.length) {
      const wait = Math.ceil(keyPool.nextAvailableInMs('groq', chosenModel) / 1000);
      lastError = lastError || new ProviderError('PROVIDER_RATE_LIMITED', `All Groq keys are cooling down for ${chosenModel}`, { retryAfter: wait });
      continue;
    }
    for (const entry of keys) {
      if (Date.now() - t0 > MAX_TOTAL_MS) break outer;
      const started = Date.now();
      const ref = keyPool.keyRef('groq', entry);
      try {
        const { data, headers, status } = await callGroq(entry.key, { ...baseBody, model: chosenModel });
        const choice = data.choices[0] || {};
        const text = choice.message && choice.message.content ? choice.message.content : '';
        const usage = data.usage || {};
        const cachedPresent = usage.prompt_tokens_details && typeof usage.prompt_tokens_details.cached_tokens === 'number';
        t.addAttempt({
          provider: 'groq', model: chosenModel, keyRef: ref, startedAt: started, durationMs: Date.now() - started, httpStatus: status, success: true,
          headers, usage, responseText: text, toolCalls: choice.message && choice.message.tool_calls, finishReason: choice.finish_reason,
          systemFingerprint: data.system_fingerprint, providerRequestId: data.x_groq && data.x_groq.id, cacheRequested: !!opts.cache || cachedPresent,
          providerMetadata: { id: data.id, model: data.model, x_groq: data.x_groq, service_tier: data.service_tier },
        });
        keyPool.markGood('groq', entry);
        t.finish({ success: true, finalProvider: 'groq', finalModel: chosenModel });
        const result = { model: chosenModel, response: text, usage, keyId: entry.id, request_id: t.requestId };
        if (choice.message && choice.message.tool_calls) result.tool_calls = choice.message.tool_calls;
        if (choice.finish_reason) result.finish_reason = choice.finish_reason;
        return result;
      } catch (err) {
        if (!(err instanceof ProviderError)) {
          t.addAttempt({ provider: 'groq', model: chosenModel, keyRef: ref, startedAt: started, durationMs: Date.now() - started, success: false, error: err });
          t.finish({ success: false, error: err });
          throw err;
        }
        t.addAttempt({ provider: 'groq', model: chosenModel, keyRef: ref, startedAt: started, durationMs: Date.now() - started, success: false, error: err, httpStatus: err.status, headers: err.headers });
        lastError = err;

        if (err.code === 'PROVIDER_RATE_LIMITED') {
          console.warn(`[groq] key ${ref} rate limited on ${chosenModel}; rotating`);
          keyPool.markLimited('groq', entry, chosenModel, err.retryAfter);
          if (err.retryAfter) minRetry = minRetry ? Math.min(minRetry, err.retryAfter) : err.retryAfter;
          continue; // next key
        }
        if (err.code === 'PROVIDER_AUTH_FAILED') {
          console.warn(`[groq] key ${ref} rejected; rotating`);
          keyPool.markDead('groq', entry);
          continue; // next key
        }
        if (['MODEL_NOT_FOUND', 'CONTEXT_TOO_LARGE', 'UNSUPPORTED_MODALITY', 'UPSTREAM_TIMEOUT', 'PROVIDER_NETWORK_ERROR', 'PROVIDER_UNAVAILABLE', 'MALFORMED_RESPONSE'].includes(err.code)) {
          break; // not a key problem: move to the next model
        }
        t.finish({ success: false, error: err }); // non-recoverable (e.g. other 4xx)
        throw err;
      }
    }
  }

  let finalErr = lastError;
  if (!finalErr) finalErr = new ProviderError('PROVIDER_EXECUTION_FAILED', 'No Groq model/key could be attempted');
  else if (finalErr.code === 'PROVIDER_RATE_LIMITED') {
    finalErr = new ProviderError('PROVIDER_RATE_LIMITED', `All Groq keys/models exhausted (${keyPool.count('groq')} keys, ${candidates.length} models)`, { retryAfter: minRetry || finalErr.retryAfter || 0, status: 429 });
  }
  t.finish({ success: false, error: finalErr });
  throw finalErr;
}

async function healthCheck() {
  const gcfg = config.providers.groq;
  keyPool.setFallbackKey('groq', gcfg && gcfg.apiKey);
  const total = keyPool.count('groq');
  if (total === 0) return { healthy: false, reason: 'not_configured' };
  const available = keyPool.availableKeys('groq', gcfg.defaultModel).length;
  return { healthy: available > 0, keys: total, available };
}

module.exports = { execute, healthCheck, ProviderError };
AIG_GROQ_EOF

# --- additive instrumentation of the other provider modules (append-only, guarded at runtime)
WRAPPED=()
shopt -s nullglob
for f in src/providers/*.js; do
  base="$(basename "$f" .js)"
  case "$base" in registry|index|groq|keyPool) continue ;; esac
  if grep -q 'AIG_INSTRUMENT_V1\|AIG_TELEMETRY_V1' "$f"; then log "already instrumented: $f"; continue; fi
  if grep -q 'module\.exports' "$f" && grep -q 'execute' "$f"; then
    backup_file "$f"
    {
      printf '\n// AIG_INSTRUMENT_V1: additive telemetry wrapper (guarded; no behaviour change if unavailable)\n'
      printf "try { const __aig = require('../lib/instrument'); if (module.exports && typeof module.exports.execute === 'function') module.exports.execute = __aig.wrap('%s', module.exports.execute); } catch (_) { /* telemetry unavailable */ }\n" "$base"
    } >> "$f"
    CHANGED_JS+=("$f"); FILES_CHANGED=1; WRAPPED+=("$f")
    log "instrumented provider: $f"
  else
    warn "skipped $f: no 'module.exports' + 'execute' (not auto-instrumented)"
  fi
done
shopt -u nullglob

# --- syntax validation of every JS file we touched
log "--- syntax check ---"
for f in "${CHANGED_JS[@]}"; do
  node --check "$ROOT/$f" || die 6 "syntax error in $f (files will be restored)"
done
log "syntax OK for ${#CHANGED_JS[@]} file(s)"

# ------------------------------------------------------------------ 7. documentation and env template
install_file docs/AI_TELEMETRY.md <<'AIG_DOC_EOF'
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
AIG_DOC_EOF

if [[ -f .env.example ]]; then
  ENV_ADD=""
  for kv in "AIG_TELEMETRY_ENABLED=true" "AIG_STORE_PAYLOADS=true" "AIG_MAX_TEXT_BYTES=262144" "GROQ_FALLBACK_MODELS=" "GROQ_API_KEY_1=" "GROQ_API_KEY_2=" "GEMINI_API_KEY_1=" "GEMINI_API_KEY_2=" "AIG_MAX_TOTAL_MS=60000" "AIG_IMAGE_STORE_DIR="; do
    grep -q "^${kv%%=*}=" .env.example || ENV_ADD+="$kv"$'\n'
  done
  if [[ -n "$ENV_ADD" ]]; then
    backup_file .env.example; FILES_CHANGED=1
    { printf '\n# --- AI gateway telemetry / key pools (added by upgrade) ---\n'; printf '%s' "$ENV_ADD"; } >> .env.example
    log "appended new variables to .env.example"
  fi
fi

# ------------------------------------------------------------------ 8. rebuild and verify
if [[ "$NO_RESTART" == "1" ]]; then
  warn "--no-restart set: skipping image rebuild and runtime verification"
  COMPLETED=1
  log "done (files + migration applied). Rebuild with: ${COMPOSE[*]} up -d --build $API_SERVICE"
  exit 0
fi

log "--- rebuilding and starting $API_SERVICE ---"
RESTARTED=1
"${COMPOSE[@]}" up -d --build "$API_SERVICE" >/dev/null || die 7 "docker build/up failed"

log "checking new modules are inside the image"
"${COMPOSE[@]}" run --rm --no-deps -T --entrypoint sh "$API_SERVICE" -c 'for f in redact keyPool telemetry instrument aiMetrics; do test -f /app/src/lib/$f.js || { echo "missing /app/src/lib/$f.js"; exit 1; }; done' \
  || die 7 "new files are not in the image (check Dockerfile COPY / .dockerignore / bind mounts)"

HEALTH_PATHS="/health,/healthz,/ready"
HEALTH_JS='const http=require("http");const ports=[process.env.PORT,process.env.APP_PORT,8080,3000,4000].filter(Boolean);const paths=(process.argv[1]||"/health").split(",");const list=[];for(const p of ports)for(const q of paths)list.push([p,q]);let i=0;(function next(){if(i>=list.length)process.exit(1);const [p,q]=list[i++];const r=http.get({host:"127.0.0.1",port:p,path:q,timeout:3000},res=>{res.resume();if(res.statusCode>=200&&res.statusCode<400){console.log("health "+p+" "+q+" -> "+res.statusCode);process.exit(0)}next()});r.on("error",next);r.on("timeout",()=>r.destroy())})();'

log "waiting for health endpoint"
healthy=0
for _ in $(seq 1 30); do
  if "${COMPOSE[@]}" exec -T "$API_SERVICE" node -e "$HEALTH_JS" "$HEALTH_PATHS" 2>/dev/null; then healthy=1; break; fi
  sleep 2
done
[[ $healthy -eq 1 ]] || { "${COMPOSE[@]}" logs --tail=40 "$API_SERVICE" || true; die 7 "gateway did not become healthy"; }

if "${COMPOSE[@]}" exec -T "$API_SERVICE" node -e "$HEALTH_JS" "/capabilities" 2>/dev/null; then log "existing /capabilities route still responds"; else warn "/capabilities did not respond 2xx/3xx (verify existing routes manually)"; fi

log "provider registry load check"
"${COMPOSE[@]}" exec -T "$API_SERVICE" node -e 'try{const r=require("/app/src/providers/registry");console.log("registry exports:",Object.keys(r).join(","));}catch(e){console.error(e.message);process.exit(1)}process.exit(0)' \
  || die 7 "provider registry failed to load inside the container"

log "configured key variable names in $API_SERVICE (names only):"
"${COMPOSE[@]}" exec -T "$API_SERVICE" sh -c 'env | cut -d= -f1 | grep -E "^(GROQ|GEMINI)_API_KEY|^AIG_|^POSTGRES_" | sort' | sed 's/^/    /' || true

if [[ "$SKIP_TESTS" != "1" ]] && node -e 'const p=require("./package.json");process.exit(p.scripts&&p.scripts.test&&!/no test specified/.test(p.scripts.test)?0:1)'; then
  log "running existing test suite"
  if ! "${COMPOSE[@]}" run --rm --no-deps -T "$API_SERVICE" npm test; then
    if [[ "${AIG_STRICT_TESTS:-0}" == "1" ]]; then die 7 "existing tests failed"; else warn "existing tests failed (may pre-date this upgrade); set AIG_STRICT_TESTS=1 to make this fatal"; fi
  fi
else
  log "no runnable test script (or skipped)"
fi

# ------------------------------------------------------------------ 9. telemetry persistence self-test (always rolled back)
NO_ROLLBACK=1   # a telemetry problem must not roll back otherwise-working code
log "--- telemetry self-test (writes every record type inside a transaction that is rolled back) ---"
ST_OUT="$("${COMPOSE[@]}" exec -T "$API_SERVICE" node -e 'require("/app/src/lib/telemetry").selfTest().then(r=>{console.log(JSON.stringify(r));process.exit(r.ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})' 2>&1)" || {
  printf '%s\n' "$ST_OUT"
  die 8 "telemetry self-test failed. The gateway keeps working (telemetry is fail-open). Check the error above and the POSTGRES_* values in .env."
}
log "self-test result: $ST_OUT"
echo "$ST_OUT" | grep -q '"redacted_header_present":false' || die 8 "redaction check failed: authorization header survived sanitisation"

COMPLETED=1
log "=============================================================="
log "UPGRADE COMPLETE"
log "  migration      : $MIG_REL (applied + verified)"
log "  DB backup      : $DB_BACKUP"
log "  file backups   : $BACKUP_DIR (rollback: $SCRIPT_PATH --rollback-files '$BACKUP_DIR')"
log "  instrumented   : groq (native) ${WRAPPED[*]:-}"
log "  docs           : docs/AI_TELEMETRY.md"
log "  next steps     : add GROQ_API_KEY_1..N and GROQ_FALLBACK_MODELS to .env; insert model limits/capabilities into aig_models;"
log "                   pass a shared UUID request_id from src/lib/router.js / executionService.js to chain groq -> gemini attempts."
exit 0
