#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PATCH: Stack 3 (PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT)
#   - Implements Gemini as a real provider (fixes PROVIDER_NOT_IMPLEMENTED)
#   - Fixes GROQ_DEFAULT_MODEL / GEMINI_DEFAULT_MODEL pointing at retired models
#     (llama-3.1-8b-instant, gemini-1.5-flash are both shut down as of Aug 2026)
#   - Adds capability/intent-based routing: /v1/chat and /v1/execute now accept
#     an optional "capability" (alias "intent") field. The router picks a
#     worker (provider+model) tagged with that capability instead of you
#     having to hardcode a provider name, and falls back to plain
#     round-robin auto-selection if nothing matches.
#   - Adds GET /capabilities to introspect known capability tags and which
#     workers can serve each one.
#
# Run this from the root of your PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT
# checkout (the directory containing src/, docker-compose.yml, etc).
# Safe to re-run: every write is idempotent (content-hash compared) and a
# .bak is kept the first time a file is touched.
# ==============================================================================

REPO_ROOT="${1:-$(pwd)}"
cd "$REPO_ROOT"

if [ ! -f "package.json" ] || [ ! -d "src" ]; then
  echo "[FATAL] $REPO_ROOT does not look like the Stack 3 repo root (expected package.json + src/)." >&2
  echo "        Usage: ./patch-day3-gemini-capabilities.sh /path/to/PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT" >&2
  exit 1
fi

_log()  { echo -e "\033[1;36m[PATCH]\033[0m $*"; }
_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
_info() { echo -e "\033[1;90m[INFO]\033[0m $*"; }

# write_if_changed <path> <<'EOF' ... EOF
# Idempotent write: only touches the file (and takes a one-time .bak) if the
# new content actually differs from what's on disk.
write_if_changed() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"

  mkdir -p "$(dirname "$target")"

  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    _info "unchanged: $target"
    rm -f "$tmp"
    return 0
  fi

  if [ -f "$target" ] && [ ! -f "${target}.bak" ]; then
    cp "$target" "${target}.bak"
    _info "backed up: $target -> ${target}.bak"
  fi

  mv "$tmp" "$target"
  _ok "wrote: $target"
}

_log "=== Patching src/lib/config.js (Gemini implemented + capability tags) ==="
write_if_changed "src/lib/config.js" <<'EOF'
require('dotenv').config();

function bool(v, def = false) {
  if (v === undefined || v === null || v === '') return def;
  return String(v).toLowerCase() === 'true';
}

// Capability tags let the router pick a worker (provider+model) by what the
// caller needs ("chat", "reasoning", "vision", ...) instead of a hardcoded
// provider name. A model may carry more than one tag. Tags are intentionally
// coarse-grained; refine per your own traffic once you have data.
const GROQ_MODELS = {
  'openai/gpt-oss-20b': { capabilities: ['chat', 'fast', 'general'] },
  'openai/gpt-oss-120b': { capabilities: ['reasoning', 'code', 'complex', 'general'] },
  'qwen/qwen3.6-27b': { capabilities: ['vision', 'multimodal', 'reasoning', 'chat'] },
};

const GEMINI_MODELS = {
  'gemini-3.5-flash-lite': { capabilities: ['fast', 'classification', 'chat'] },
  'gemini-3.6-flash': { capabilities: ['chat', 'code', 'general', 'multimodal'] },
  'gemini-3.1-pro': { capabilities: ['reasoning', 'complex', 'long_context', 'multimodal'] },
};

module.exports = {
  port: parseInt(process.env.PORT || '8080', 10),
  serviceName: process.env.SERVICE_NAME || 'ai-gateway-3-of-10-provider-routing',
  nodeEnv: process.env.NODE_ENV || 'production',

  postgres: {
    host: process.env.POSTGRES_HOST || 'postgres',
    port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    database: process.env.POSTGRES_DB || 'ai_gateway_routing',
    user: process.env.POSTGRES_USER || 'ai_gateway',
    password: process.env.POSTGRES_PASSWORD || '',
  },

  redis: {
    host: process.env.REDIS_HOST || 'redis',
    port: parseInt(process.env.REDIS_PORT || '6379', 10),
  },

  providers: {
    groq: {
      apiKey: process.env.GROQ_API_KEY || '',
      // llama-3.1-8b-instant / llama-3.3-70b-versatile were retired by Groq
      // (shutdown Aug 16, 2026) — openai/gpt-oss-20b is the recommended
      // successor and stays fast + cheap for general chat.
      defaultModel: process.env.GROQ_DEFAULT_MODEL || 'openai/gpt-oss-20b',
      enabled: bool(process.env.GROQ_ENABLED, true),
      baseUrl: process.env.GROQ_BASE_URL || 'https://api.groq.com/openai/v1',
      implemented: true,
      models: GROQ_MODELS,
    },
    gemini: {
      apiKey: process.env.GEMINI_API_KEY || '',
      // gemini-1.5-flash is fully retired. gemini-3.6-flash is the current
      // GA workhorse (coding/agentic, good price/perf).
      defaultModel: process.env.GEMINI_DEFAULT_MODEL || 'gemini-3.6-flash',
      enabled: bool(process.env.GEMINI_ENABLED, true),
      baseUrl: process.env.GEMINI_BASE_URL || 'https://generativelanguage.googleapis.com/v1beta',
      implemented: true,
      models: GEMINI_MODELS,
    },
  },
};
EOF

_log "=== Adding src/providers/gemini.js ==="
write_if_changed "src/providers/gemini.js" <<'EOF'
// PATCH_MARKER_GEMINI_PROVIDER_V1
const fetch = require('node-fetch');
const config = require('../lib/config');

class ProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// Gemini's generateContent API has no "system" role in contents[]; system
// messages are folded into a top-level systemInstruction instead, and
// "assistant" turns must be relabeled "model".
function toGeminiPayload(messages) {
  const contents = [];
  let systemInstruction;
  for (const m of messages) {
    if (m.role === 'system') {
      systemInstruction = systemInstruction ? `${systemInstruction}\n${m.content}` : m.content;
      continue;
    }
    contents.push({
      role: m.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: m.content }],
    });
  }
  return { contents, systemInstruction };
}

async function execute({ message, model, temperature, instruction, messages: structuredMessages, max_tokens }) {
  const apiKey = config.providers.gemini.apiKey;
  if (!apiKey) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'Gemini API key is not configured');
  }

  const chosenModel = model || config.providers.gemini.defaultModel;

  // Same normalization contract as groq.js: structured messages[] (from
  // /v1/execute, or normalized by /v1/chat) take precedence over the legacy
  // {message, instruction} shape.
  let messages;
  if (Array.isArray(structuredMessages) && structuredMessages.length > 0) {
    messages = structuredMessages.map((m) => ({ role: m.role || 'user', content: m.content }));
  } else {
    messages = [];
    if (instruction) {
      messages.push({ role: 'system', content: instruction });
    }
    messages.push({ role: 'user', content: message });
  }

  const { contents, systemInstruction } = toGeminiPayload(messages);

  const requestBody = {
    contents,
    generationConfig: {
      temperature: typeof temperature === 'number' ? temperature : 0.3,
    },
  };
  if (systemInstruction) {
    requestBody.systemInstruction = { parts: [{ text: systemInstruction }] };
  }
  if (typeof max_tokens === 'number') {
    requestBody.generationConfig.maxOutputTokens = max_tokens;
  }

  const url = `${config.providers.gemini.baseUrl}/models/${encodeURIComponent(chosenModel)}:generateContent`;

  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify(requestBody),
      timeout: 20000,
    });
  } catch (err) {
    if (err.type === 'request-timeout') {
      throw new ProviderError('UPSTREAM_TIMEOUT', 'Gemini request timed out');
    }
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Gemini: ${err.message}`);
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }
    if (response.status === 401 || response.status === 403) {
      throw new ProviderError('PROVIDER_AUTH_FAILED', 'Gemini rejected the API key');
    }
    if (response.status === 429) {
      throw new ProviderError('PROVIDER_RATE_LIMITED', 'Gemini rate limit exceeded');
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Gemini does not recognize model "${chosenModel}"`);
    }
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Gemini returned status ${response.status}: ${bodyText.slice(0, 300)}`);
  }

  const data = await response.json();
  const candidate = data.candidates && data.candidates[0];
  const parts = candidate && candidate.content && candidate.content.parts;
  const text = Array.isArray(parts) ? parts.map((p) => p.text || '').join('') : '';

  const usage = data.usageMetadata
    ? {
      prompt_tokens: data.usageMetadata.promptTokenCount,
      completion_tokens: data.usageMetadata.candidatesTokenCount,
      total_tokens: data.usageMetadata.totalTokenCount,
    }
    : {};

  return {
    model: chosenModel,
    response: text,
    usage,
  };
}

async function healthCheck() {
  if (!config.providers.gemini.apiKey) {
    return { healthy: false, reason: 'not_configured' };
  }
  return { healthy: true };
}

module.exports = { execute, healthCheck, ProviderError };
EOF

_log "=== Patching src/providers/registry.js (capability worker catalog) ==="
write_if_changed "src/providers/registry.js" <<'EOF'
// PATCH_MARKER_REGISTRY_CAPABILITIES_V1
const config = require('../lib/config');
const groq = require('./groq');
const gemini = require('./gemini');

// Provider registry describing state: implemented / enabled / configured / healthy.
// Each provider also carries a `models` catalog (model id -> capability tags)
// so the router can pick a worker by capability/intent, not just by name.
function buildRegistry() {
  return {
    groq: {
      name: 'groq',
      implemented: config.providers.groq.implemented,
      enabled: config.providers.groq.enabled,
      configured: Boolean(config.providers.groq.apiKey),
      defaultModel: config.providers.groq.defaultModel,
      models: config.providers.groq.models,
      execute: groq.execute,
      healthCheck: groq.healthCheck,
    },
    gemini: {
      name: 'gemini',
      implemented: config.providers.gemini.implemented,
      enabled: config.providers.gemini.enabled,
      configured: Boolean(config.providers.gemini.apiKey),
      defaultModel: config.providers.gemini.defaultModel,
      models: config.providers.gemini.models,
      execute: gemini.execute,
      healthCheck: gemini.healthCheck,
    },
  };
}

function publicProviderList() {
  const reg = buildRegistry();
  return Object.values(reg).map((p) => ({
    name: p.name,
    implemented: p.implemented,
    enabled: p.enabled,
    configured: p.configured,
    defaultModel: p.defaultModel,
    models: Object.entries(p.models || {}).map(([id, meta]) => ({
      id,
      capabilities: meta.capabilities || [],
    })),
  }));
}

function implementedAvailableProviders() {
  const reg = buildRegistry();
  return Object.values(reg).filter((p) => p.implemented && p.enabled && p.configured);
}

function getProvider(name) {
  const reg = buildRegistry();
  return reg[name] || null;
}

// Flat list of every (provider, model) pair the registry knows about,
// regardless of current availability — used to answer "what could serve
// this capability" (GET /capabilities) as well as to drive routing.
function listWorkers() {
  const reg = buildRegistry();
  const workers = [];
  for (const p of Object.values(reg)) {
    if (!p.implemented) continue;
    for (const [modelId, meta] of Object.entries(p.models || {})) {
      workers.push({
        provider: p.name,
        model: modelId,
        capabilities: meta.capabilities || [],
        available: Boolean(p.enabled && p.configured),
      });
    }
  }
  return workers;
}

function workersForCapability(capability) {
  return listWorkers().filter((w) => w.capabilities.includes(capability));
}

function allCapabilities() {
  const set = new Set();
  for (const w of listWorkers()) {
    for (const c of w.capabilities) set.add(c);
  }
  return Array.from(set).sort();
}

module.exports = {
  buildRegistry,
  publicProviderList,
  implementedAvailableProviders,
  getProvider,
  listWorkers,
  workersForCapability,
  allCapabilities,
};
EOF

_log "=== Patching src/lib/router.js (capability-aware resolution) ==="
write_if_changed "src/lib/router.js" <<'EOF'
// PATCH_MARKER_ROUTER_CAPABILITIES_V1
const registry = require('../providers/registry');
const redisClient = require('./redisClient');

class RoutingError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * Deterministic provider (+ optional model) resolution strategy:
 *   1. Explicit provider (must be implemented+enabled+configured, or error).
 *      An explicit model, if also given, is honored as-is.
 *   2. No explicit provider, but a capability/intent hint is given: pick a
 *      worker (provider+model) whose capability tags include it, restricted
 *      to implemented+enabled+configured providers. Deterministic
 *      round-robin (Redis-backed) across matching workers. If no worker
 *      matches the capability, this falls through to step 3 rather than
 *      erroring — capability hints are a routing preference, not a
 *      hard requirement.
 *   3. Automatic selection ("auto", omitted provider, or an unmatched
 *      capability): deterministic Redis-backed round-robin across all
 *      implemented+enabled+configured providers, using each provider's
 *      default model.
 *   4. Fallback: first healthy implemented provider (used if Redis is
 *      unavailable at any of the steps above).
 *
 * Returns { provider, model } — model may be undefined, in which case the
 * caller (executionService) falls back to provider.defaultModel.
 */
async function resolveProvider({ provider, model, capability }) {
  if (provider && provider !== 'auto') {
    const requested = registry.getProvider(provider);
    if (!requested) {
      throw new RoutingError('PROVIDER_NOT_FOUND', `Unknown provider: ${provider}`);
    }
    if (!requested.implemented) {
      throw new RoutingError('PROVIDER_NOT_IMPLEMENTED', `Provider not implemented: ${provider}`);
    }
    if (!requested.enabled) {
      throw new RoutingError('PROVIDER_DISABLED', `Provider disabled: ${provider}`);
    }
    if (!requested.configured) {
      throw new RoutingError('PROVIDER_NOT_CONFIGURED', `Provider not configured: ${provider}`);
    }
    return { provider: requested, model };
  }

  if (!model && capability) {
    const candidates = registry.workersForCapability(capability).filter((w) => w.available);
    if (candidates.length > 0) {
      let idx = 0;
      try {
        idx = await redisClient.nextRoutingIndex(`routing:capability:${capability}:cursor`, candidates.length);
      } catch (_) {
        idx = 0;
      }
      const chosen = candidates[idx];
      return { provider: registry.getProvider(chosen.provider), model: chosen.model };
    }
    // No worker advertises this capability right now — fall through to
    // generic auto-selection below rather than failing the request.
  }

  const available = registry.implementedAvailableProviders();
  if (available.length === 0) {
    throw new RoutingError('PROVIDER_UNAVAILABLE', 'No available provider could execute this request');
  }

  try {
    const idx = await redisClient.nextRoutingIndex('routing:auto:cursor', available.length);
    return { provider: available[idx], model };
  } catch (_) {
    // Fallback: first healthy implemented provider.
    return { provider: available[0], model };
  }
}

module.exports = { resolveProvider, RoutingError };
EOF

_log "=== Patching src/lib/executionService.js (capability passthrough) ==="
write_if_changed "src/lib/executionService.js" <<'EOF'
// PATCH_MARKER_EXECUTION_SERVICE_V2
// Shared execution service used by both /v1/chat and /v1/execute so that
// provider routing, execution, normalization, logging, metrics and
// persistence are not duplicated between the two HTTP contracts.
//
// /v1/chat        -> builds a messages[] array from {message, instruction}
// /v1/execute     -> passes messages[] directly (Stack 5 execution contract)
// Both call runExecution() below and format their own HTTP response shape.
//
// V2 adds an optional `capability` (alias: `intent`) hint that lets callers
// (e.g. an upstream classify layer) ask for "reasoning", "vision", "code",
// etc. without naming a specific provider — see src/lib/router.js.
const router_lib = require('./router');
const logger = require('./logger');
const metrics = require('./metrics');
const db = require('./db');

class ExecutionError extends Error {
  constructor(code, message, status) {
    super(message);
    this.code = code;
    this.status = status || 502;
  }
}

const VALID_ROLES = ['system', 'user', 'assistant'];

function validateMessages(messages) {
  if (!Array.isArray(messages) || messages.length === 0) {
    throw new ExecutionError('INVALID_REQUEST', '"messages" is required and must be a non-empty array', 400);
  }
  for (const m of messages) {
    if (!m || typeof m !== 'object' || Array.isArray(m)) {
      throw new ExecutionError('INVALID_REQUEST', 'each entry in "messages" must be an object with "role" and "content"', 400);
    }
    if (typeof m.content !== 'string' || m.content.trim() === '') {
      throw new ExecutionError('INVALID_REQUEST', 'each message requires a non-empty string "content"', 400);
    }
    if (m.role !== undefined && !VALID_ROLES.includes(m.role)) {
      throw new ExecutionError('INVALID_REQUEST', `invalid message role: ${m.role}`, 400);
    }
  }
}

function validateOptionalNumber(value, name) {
  if (value !== undefined && value !== null && typeof value !== 'number') {
    throw new ExecutionError('INVALID_REQUEST', `"${name}" must be a number when provided`, 400);
  }
}

function validateOptionalString(value, name) {
  if (value !== undefined && value !== null && typeof value !== 'string') {
    throw new ExecutionError('INVALID_REQUEST', `"${name}" must be a string when provided`, 400);
  }
}

/**
 * Resolve a provider (and optionally a model, via capability routing),
 * execute the request against it, normalize the response, and record
 * metrics/logs/persistence. Throws ExecutionError (with .code and .status)
 * on any failure so callers can format their own HTTP error body.
 */
async function runExecution({ requestId, provider, model, capability, messages, temperature, max_tokens }) {
  validateMessages(messages);
  validateOptionalNumber(temperature, 'temperature');
  validateOptionalNumber(max_tokens, 'max_tokens');
  validateOptionalString(capability, 'capability');

  const startedAt = Date.now();
  let selectedProvider;
  let routedModel;

  try {
    const routed = await router_lib.resolveProvider({ provider, model, capability });
    selectedProvider = routed.provider;
    routedModel = routed.model;
  } catch (err) {
    const code = err.code || 'PROVIDER_UNAVAILABLE';
    logger.error({
      request_id: requestId, operation: 'route_resolution', success: false,
      error_code: code, capability: capability || null, duration: Date.now() - startedAt,
    });
    await db.recordRequest({
      requestId, provider: null, model: model || null, success: false,
      errorCode: code, durationMs: Date.now() - startedAt,
    });
    throw new ExecutionError(code, err.message, 503);
  }

  const resolvedModel = model || routedModel || selectedProvider.defaultModel;
  metrics.providerRequestsTotal.inc({ provider: selectedProvider.name, model: resolvedModel });
  const timer = metrics.providerRequestDurationSeconds.startTimer({
    provider: selectedProvider.name, model: resolvedModel,
  });

  try {
    const result = await selectedProvider.execute({
      messages, model: resolvedModel, temperature, max_tokens,
    });
    timer();
    metrics.providerRequestsSuccessTotal.inc({ provider: selectedProvider.name, model: resolvedModel });

    const durationMs = Date.now() - startedAt;
    logger.info({
      request_id: requestId, provider: selectedProvider.name, model: resolvedModel,
      capability: capability || null, operation: 'execute', duration: durationMs, success: true,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model: resolvedModel, success: true, durationMs,
    });

    return {
      provider: selectedProvider.name,
      model: result.model || resolvedModel,
      response: result.response,
      usage: result.usage || {},
      durationMs,
    };
  } catch (err) {
    timer();
    const code = err.code || 'PROVIDER_EXECUTION_FAILED';
    metrics.providerRequestsFailedTotal.inc({ provider: selectedProvider.name, model: resolvedModel, error_code: code });

    const durationMs = Date.now() - startedAt;
    logger.error({
      request_id: requestId, provider: selectedProvider.name, model: resolvedModel,
      capability: capability || null, operation: 'execute', duration: durationMs, success: false, error_code: code,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model: resolvedModel, success: false, errorCode: code, durationMs,
    });

    throw new ExecutionError(code, err.message, 502);
  }
}

module.exports = { runExecution, validateMessages, validateOptionalNumber, validateOptionalString, ExecutionError };
EOF

_log "=== Patching src/routes/chat.js (capability/intent passthrough) ==="
write_if_changed "src/routes/chat.js" <<'EOF'
// PATCH_MARKER_CHAT_ROUTE_V2
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const executionService = require('../lib/executionService');
const metrics = require('../lib/metrics');

const router = express.Router();

router.post('/v1/chat', async (req, res) => {
  const requestId = req.headers['x-request-id'] || uuidv4();
  res.setHeader('X-Request-ID', requestId);

  metrics.chatRequestsTotal.inc();

  const body = req.body || {};
  const message = body.message;

  if (!message || typeof message !== 'string') {
    metrics.chatRequestsFailedTotal.inc();
    return res.status(400).json({
      success: false,
      error: { code: 'INVALID_REQUEST', message: '"message" is required and must be a string' },
      request_id: requestId,
    });
  }

  // /v1/chat keeps its existing single-message contract, but internally
  // normalizes to the same messages[] shape /v1/execute uses, and runs
  // through the same shared routing/execution service so provider
  // execution logic is not duplicated between the two endpoints.
  const messages = [];
  if (body.instruction) {
    messages.push({ role: 'system', content: body.instruction });
  }
  messages.push({ role: 'user', content: message });

  // Optional capability/intent hint (e.g. from an upstream classify layer).
  // "intent" is accepted as an alias so callers that already send
  // {"intent": "..."} don't need to rename the field.
  const capability = body.capability || body.intent;

  try {
    const result = await executionService.runExecution({
      requestId,
      provider: body.provider,
      model: body.model,
      capability,
      messages,
      temperature: body.temperature,
      max_tokens: body.max_tokens,
    });
    metrics.chatRequestsSuccessTotal.inc();

    return res.status(200).json({
      success: true,
      provider: result.provider,
      model: result.model,
      message,
      response: result.response,
      usage: result.usage,
      request_id: requestId,
    });
  } catch (err) {
    metrics.chatRequestsFailedTotal.inc();
    const code = err.code || 'PROVIDER_EXECUTION_FAILED';
    return res.status(err.status || 502).json({
      success: false,
      error: { code, message: err.message },
      request_id: requestId,
    });
  }
});

module.exports = router;
EOF

_log "=== Patching src/routes/execute.js (capability/intent passthrough) ==="
write_if_changed "src/routes/execute.js" <<'EOF'
// PATCH_MARKER_EXECUTE_ROUTE_V2
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const executionService = require('../lib/executionService');
const metrics = require('../lib/metrics');

const router = express.Router();

// POST /v1/execute - provider-neutral execution contract consumed by
// upstream orchestration (Stack 5). Stack 5 has already decided which
// worker/provider/model to use, OR can pass a `capability`/`intent` hint
// and let this stack's router pick a worker; this endpoint validates the
// request, resolves the provider through the same routing layer as
// /v1/chat, executes it, and returns a normalized, provider-neutral result.
//
// This is NOT an alias of /v1/chat: it accepts structured messages[],
// does not require a single "message" string, and does not echo one
// back in the response.
router.post('/v1/execute', async (req, res) => {
  const requestId = req.headers['x-request-id'] || uuidv4();
  res.setHeader('X-Request-ID', requestId);

  metrics.executeRequestsTotal.inc();

  const body = req.body || {};
  const { provider, model, messages, temperature, max_tokens } = body;
  const capability = body.capability || body.intent;

  try {
    executionService.validateMessages(messages);
    executionService.validateOptionalNumber(temperature, 'temperature');
    executionService.validateOptionalNumber(max_tokens, 'max_tokens');
    executionService.validateOptionalString(capability, 'capability');
  } catch (err) {
    metrics.executeRequestsFailedTotal.inc();
    return res.status(err.status || 400).json({
      success: false,
      error: { code: err.code || 'INVALID_REQUEST', message: err.message },
      request_id: requestId,
    });
  }

  try {
    const result = await executionService.runExecution({
      requestId, provider, model, capability, messages, temperature, max_tokens,
    });
    metrics.executeRequestsSuccessTotal.inc();

    return res.status(200).json({
      success: true,
      provider: result.provider,
      model: result.model,
      response: result.response,
      usage: result.usage,
      request_id: requestId,
    });
  } catch (err) {
    metrics.executeRequestsFailedTotal.inc();
    const code = err.code || 'PROVIDER_EXECUTION_FAILED';
    return res.status(err.status || 502).json({
      success: false,
      error: { code, message: err.message },
      request_id: requestId,
    });
  }
});

module.exports = router;
EOF

_log "=== Patching src/routes/meta.js (GET /capabilities) ==="
write_if_changed "src/routes/meta.js" <<'EOF'
// PATCH_MARKER_META_ROUTE_V2
const express = require('express');
const config = require('../lib/config');
const db = require('../lib/db');
const redisClient = require('../lib/redisClient');
const registry = require('../providers/registry');
const metrics = require('../lib/metrics');

const router = express.Router();

router.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    service: config.serviceName,
    timestamp: new Date().toISOString(),
  });
});

router.get('/ready', async (req, res) => {
  const checks = { postgres: false, redis: false };
  try {
    checks.postgres = await db.ping();
  } catch (_) { checks.postgres = false; }
  try {
    checks.redis = await redisClient.ping();
  } catch (_) { checks.redis = false; }

  const ready = checks.postgres && checks.redis;
  res.status(ready ? 200 : 503).json({
    status: ready ? 'ready' : 'not_ready',
    checks,
  });
});

router.get('/dependencies', async (req, res) => {
  const deps = {
    postgres: { host: config.postgres.host, port: config.postgres.port, reachable: false },
    redis: { host: config.redis.host, port: config.redis.port, reachable: false },
  };
  try { deps.postgres.reachable = await db.ping(); } catch (_) { /* noop */ }
  try { deps.redis.reachable = await redisClient.ping(); } catch (_) { /* noop */ }
  res.json({ dependencies: deps });
});

router.get('/providers', (req, res) => {
  res.json({ providers: registry.publicProviderList() });
});

// GET /capabilities - which capability/intent tags exist right now, which
// (provider, model) workers advertise each one, and whether that worker is
// currently available (enabled+configured). Lets an upstream classify layer
// (or a human) discover valid `capability`/`intent` values without reading
// source.
router.get('/capabilities', (req, res) => {
  const workers = registry.listWorkers();
  const byCapability = {};
  for (const w of workers) {
    for (const cap of w.capabilities) {
      if (!byCapability[cap]) byCapability[cap] = [];
      byCapability[cap].push({ provider: w.provider, model: w.model, available: w.available });
    }
  }
  res.json({
    capabilities: registry.allCapabilities(),
    workers_by_capability: byCapability,
  });
});

router.get('/help', (req, res) => {
  res.json({
    service: config.serviceName,
    description: 'Day 3 - Provider Routing & Execution Stack',
    endpoints: {
      'GET /health': 'Liveness check',
      'GET /ready': 'Readiness check (postgres + redis)',
      'GET /dependencies': 'Dependency connectivity status',
      'GET /providers': 'Provider registry state, including each provider\'s model catalog and capability tags (no secrets)',
      'GET /capabilities': 'Known capability/intent tags and which (provider, model) workers can serve each one',
      'GET /help': 'This message',
      'GET /metrics': 'Prometheus metrics',
      'POST /v1/chat': 'Route and execute a single-message chat request against a provider. Accepts optional "capability" (alias "intent") to route by need instead of by provider name',
      'POST /v1/execute': 'Provider-neutral execution contract for upstream orchestration (e.g. Stack 5): resolves provider/model (directly, or via "capability"/"intent"), executes structured messages[], returns a normalized result',
    },
    routing_strategy: [
      '1. Explicit provider',
      '2. Explicit model (used once a provider is resolved)',
      '3. capability/intent hint -> round-robin across workers tagged with that capability (falls through to step 4 if none match)',
      '4. Automatic selection (auto / omitted provider) -> round-robin across all implemented+enabled+configured providers',
      '5. First healthy implemented provider (fallback if Redis is unavailable)',
    ],
  });
});

router.get('/metrics', async (req, res) => {
  res.set('Content-Type', metrics.register.contentType);
  res.end(await metrics.register.metrics());
});

module.exports = router;
EOF

_log "=== Patching .env.example ==="
if [ -f ".env.example" ]; then
  cp ".env.example" ".env.example.bak"
  python3 - "$REPO_ROOT/.env.example" <<'PYEOF' 2>/dev/null || true
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()

content = content.replace(
    "GROQ_DEFAULT_MODEL=llama-3.1-8b-instant",
    "GROQ_DEFAULT_MODEL=openai/gpt-oss-20b",
)
content = content.replace(
    "# --- Gemini Provider (registry-only, not implemented in Day 3) ---\nGEMINI_API_KEY=\nGEMINI_DEFAULT_MODEL=gemini-1.5-flash\nGEMINI_ENABLED=true\n",
    "# --- Gemini Provider ---\nGEMINI_API_KEY=\nGEMINI_DEFAULT_MODEL=gemini-3.6-flash\nGEMINI_ENABLED=true\nGEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta\n",
)
with open(path, "w") as f:
    f.write(content)
PYEOF
  _ok "updated: .env.example (GROQ_DEFAULT_MODEL, GEMINI_* defaults)"
else
  _info "no .env.example found at repo root — skipping (create one from README if needed)"
fi

echo
_ok "Patch applied."
echo
cat <<'NEXT'
Next steps:

  1. Make sure GEMINI_API_KEY is set in your real .env (get one at
     https://ai.google.dev/gemini-api/docs, or the Google AI Studio console).
     Gemini will show configured:false in GET /providers until it is set —
     same as Groq does today.

  2. Rebuild and push the image to your private registry, then redeploy:

       docker build -t 192.168.0.140:5000/ai-gateway-3-provider-routing:latest .
       docker push 192.168.0.140:5000/ai-gateway-3-provider-routing:latest
       docker service update --image 192.168.0.140:5000/ai-gateway-3-provider-routing:latest \
         <your_swarm_service_name>

     (or ./deploy-ai-gateway-3-of-10.sh build && ... up, if you're running
     via the deploy script's own compose path instead of Swarm directly)

  3. Confirm the fix:

       curl -s http://<host>:<port>/providers | jq
       curl -s http://<host>:<port>/capabilities | jq

     gemini should now show implemented:true. Once GEMINI_API_KEY is set,
     configured:true too, and the PROVIDER_NOT_IMPLEMENTED errors in your
     logs stop.

  4. Try capability-based routing (no provider named — router picks a
     worker tagged for the capability, round-robining across matches):

       curl -s -X POST http://<host>:<port>/v1/chat \
         -H 'Content-Type: application/json' \
         -d '{"message":"Summarize the CAP theorem in one sentence","capability":"fast"}'

       curl -s -X POST http://<host>:<port>/v1/execute \
         -H 'Content-Type: application/json' \
         -d '{"messages":[{"role":"user","content":"Refactor this for readability..."}],"capability":"code"}'

  5. If your Stack 1/2 classify layer already emits "intent" rather than
     "capability", nothing needs to change on that side — both field names
     are accepted as aliases.

NEXT
