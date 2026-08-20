// PATCH_MARKER_EXECUTION_SERVICE_V1
// Shared execution service used by both /v1/chat and /v1/execute so that
// provider routing, execution, normalization, logging, metrics and
// persistence are not duplicated between the two HTTP contracts.
//
// /v1/chat        -> builds a messages[] array from {message, instruction}
// /v1/execute     -> passes messages[] directly (Stack 5 execution contract)
// Both call runExecution() below and format their own HTTP response shape.
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

/**
 * Resolve a provider, execute the request against it, normalize the
 * response, and record metrics/logs/persistence. Throws ExecutionError
 * (with .code and .status) on any failure so callers can format their
 * own HTTP error body.
 */
async function runExecution({ requestId, provider, model, messages, temperature, max_tokens }) {
  validateMessages(messages);
  validateOptionalNumber(temperature, 'temperature');
  validateOptionalNumber(max_tokens, 'max_tokens');

  const startedAt = Date.now();
  let selectedProvider;

  try {
    selectedProvider = await router_lib.resolveProvider({ provider, model });
  } catch (err) {
    const code = err.code || 'PROVIDER_UNAVAILABLE';
    logger.error({
      request_id: requestId, operation: 'route_resolution', success: false,
      error_code: code, duration: Date.now() - startedAt,
    });
    await db.recordRequest({
      requestId, provider: null, model: model || null, success: false,
      errorCode: code, durationMs: Date.now() - startedAt,
    });
    throw new ExecutionError(code, err.message, 503);
  }

  const resolvedModel = model || selectedProvider.defaultModel;
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
      operation: 'execute', duration: durationMs, success: true,
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
      operation: 'execute', duration: durationMs, success: false, error_code: code,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model: resolvedModel, success: false, errorCode: code, durationMs,
    });

    throw new ExecutionError(code, err.message, 502);
  }
}

module.exports = { runExecution, validateMessages, validateOptionalNumber, ExecutionError };
