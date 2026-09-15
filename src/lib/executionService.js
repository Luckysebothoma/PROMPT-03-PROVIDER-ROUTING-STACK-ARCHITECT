// PATCH_MARKER_EXECUTION_SERVICE_V3
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
const registry = require('../providers/registry');
const redisClient = require('./redisClient');
const logger = require('./logger');
const metrics = require('./metrics');
const db = require('./db');

const N8N_COMFY_WEBHOOK_URL = process.env.N8N_COMFY_WEBHOOK_URL || null;

// 0 (default) disables the internal daily token-usage throttle entirely.
const DAILY_TOKEN_BUDGET = parseInt(process.env.DAILY_TOKEN_BUDGET || '0', 10);

// Best-effort, non-blocking notify. Never throws, never awaited by callers.
// n8n's Function node expects: { message, session_id, external_ref, title, detected_niche, variant_count }
function notifyComfyWebhook({ requestId, message, detected_niche, variant_count, external_ref }) {
  if (!N8N_COMFY_WEBHOOK_URL) return; // silently no-op if not configured
  if (!message || !String(message).trim()) return; // n8n throws on empty message, so don't bother sending

  const payload = {
    message: String(message).trim(),
    session_id: requestId,
    external_ref: external_ref || null,
    title: String(message).trim().slice(0, 60),
    detected_niche: detected_niche || null,
    variant_count: variant_count || null,
  };

  // Fire-and-forget: intentionally not awaited by the caller.
  Promise.resolve()
    .then(() => fetch(N8N_COMFY_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }))
    .then((res) => {
      if (!res.ok) {
        logger.warn({
          request_id: requestId,
          operation: 'n8n_comfy_webhook',
          success: false,
          status: res.status,
        });
      }
    })
    .catch((err) => {
      logger.warn({
        request_id: requestId,
        operation: 'n8n_comfy_webhook',
        success: false,
        error_message: err.message,
      });
    });
}



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

  // Log complete incoming payload data for tracing and debugging request issues
  logger.info({
    request_id: requestId,
    operation: 'execution_start',
    input_params: {
      provider: provider || null,
      model: model || null,
      capability: capability || null,
      temperature: temperature !== undefined ? temperature : null,
      max_tokens: max_tokens !== undefined ? max_tokens : null,
      messages_count: messages.length,
    },
    messages_payload: messages,
  });

  try {
    const routed = await router_lib.resolveProvider({ provider, model, capability });
    selectedProvider = routed.provider;
    routedModel = routed.model;
  } catch (err) {
    const code = err.code || 'PROVIDER_UNAVAILABLE';
    logger.error({
      request_id: requestId, operation: 'route_resolution', success: false,
      error_code: code, capability: capability || null, duration: Date.now() - startedAt,
      error_message: err.message,
    });
    await db.recordRequest({
      requestId, provider: null, model: model || null, success: false,
      errorCode: code, durationMs: Date.now() - startedAt,
    });
    throw new ExecutionError(code, err.message, 503);
  }

  const resolvedModel = model || routedModel || selectedProvider.defaultModel;

  // Cap/backfill max_tokens from the resolved model's configured ceiling
  // (AI_MODELS_JSON `max_completion_tokens`, when set) so a missing
  // max_tokens no longer silently falls through to the provider's own
  // uncapped default, and an oversized caller-supplied value can't exceed
  // what's actually configured for that model.
  const modelMeta = registry.modelConfig(selectedProvider.name, resolvedModel);
  const configuredCap = modelMeta && typeof modelMeta.maxCompletionTokens === 'number'
    ? modelMeta.maxCompletionTokens
    : undefined;
  const effectiveMaxTokens = configuredCap !== undefined
    ? (typeof max_tokens === 'number' ? Math.min(max_tokens, configuredCap) : configuredCap)
    : max_tokens;

  // Internal daily token budget throttle. Disabled by default
  // (DAILY_TOKEN_BUDGET=0). Fails open if Redis is unreachable — throttling
  // must never be the reason the whole gateway goes down.
  if (DAILY_TOKEN_BUDGET > 0) {
    let usedToday = 0;
    try {
      usedToday = await redisClient.getDailyTokenUsage();
    } catch (err) {
      logger.warn({ request_id: requestId, operation: 'token_budget_check', success: false, error_message: err.message });
      usedToday = 0;
    }
    if (usedToday >= DAILY_TOKEN_BUDGET) {
      logger.error({
        request_id: requestId, operation: 'token_budget_throttle', success: false,
        used_today: usedToday, daily_token_budget: DAILY_TOKEN_BUDGET,
      });
      await db.recordRequest({
        requestId, provider: selectedProvider.name, model: resolvedModel, success: false,
        errorCode: 'DAILY_TOKEN_BUDGET_EXCEEDED', durationMs: Date.now() - startedAt,
      });
      throw new ExecutionError('DAILY_TOKEN_BUDGET_EXCEEDED', `Daily token budget (${DAILY_TOKEN_BUDGET}) reached`, 429);
    }
  }

  metrics.providerRequestsTotal.inc({ provider: selectedProvider.name, model: resolvedModel });
  const timer = metrics.providerRequestDurationSeconds.startTimer({
    provider: selectedProvider.name, model: resolvedModel,
  });

  try {
    // Log outbound payload dispatched to provider API
    logger.info({
      request_id: requestId,
      operation: 'provider_dispatch',
      provider: selectedProvider.name,
      model: resolvedModel,
      temperature: temperature !== undefined ? temperature : null,
      max_tokens: effectiveMaxTokens !== undefined ? effectiveMaxTokens : null,
      messages: messages,
    });

    const result = await selectedProvider.execute({
      messages, model: resolvedModel, temperature, max_tokens: effectiveMaxTokens,
    });
    timer();
    metrics.providerRequestsSuccessTotal.inc({ provider: selectedProvider.name, model: resolvedModel });

    // Best-effort daily token budget accounting — never blocks or fails the
    // response to the caller.
    if (DAILY_TOKEN_BUDGET > 0) {
      const u = result.usage || {};
      const usageTotal = Number(u.total_tokens) || (Number(u.prompt_tokens || 0) + Number(u.completion_tokens || 0)) || 0;
      redisClient.addDailyTokenUsage(usageTotal).catch((err) => {
        logger.warn({ request_id: requestId, operation: 'token_budget_record', success: false, error_message: err.message });
      });
    }

    const durationMs = Date.now() - startedAt;
    
    // Log complete successful response data for debugging and inspection
    logger.info({
      request_id: requestId, provider: selectedProvider.name, model: resolvedModel,
      capability: capability || null, operation: 'execute_success', duration: durationMs, success: true,
      usage: result.usage || {},
      response_payload: result.response,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model: resolvedModel, success: true, durationMs,
    });


  // Best-effort side call — does not block or affect the response to the caller.
    const responseText = typeof result.response === 'string'
      ? result.response
      : (result.response && (result.response.text || result.response.content)) || '';
    notifyComfyWebhook({
      requestId,
      message: responseText,
      detected_niche: capability || null,
      variant_count: null,
      external_ref: requestId,
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
    
    // Log complete error details including provider failure messages and payloads
    logger.error({
      request_id: requestId, provider: selectedProvider.name, model: resolvedModel,
      capability: capability || null, operation: 'execute_failure', duration: durationMs, success: false, error_code: code,
      error_message: err.message,
      error_stack: err.stack,
      sent_messages: messages,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model: resolvedModel, success: false, errorCode: code, durationMs,
    });

    throw new ExecutionError(code, err.message, 502);
  }
}

module.exports = { runExecution, validateMessages, validateOptionalNumber, validateOptionalString, ExecutionError };