const express = require('express');
const { v4: uuidv4 } = require('uuid');
const router_lib = require('../lib/router');
const registry = require('../providers/registry');
const db = require('../lib/db');
const logger = require('../lib/logger');
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

  const startedAt = Date.now();
  let selectedProvider;

  try {
    selectedProvider = await router_lib.resolveProvider({
      provider: body.provider,
      model: body.model,
    });
  } catch (err) {
    metrics.chatRequestsFailedTotal.inc();
    const code = err.code || 'PROVIDER_UNAVAILABLE';
    logger.error({
      request_id: requestId, operation: 'route_resolution', success: false,
      error_code: code, duration: Date.now() - startedAt,
    });
    await db.recordRequest({
      requestId, provider: null, model: body.model, success: false,
      errorCode: code, durationMs: Date.now() - startedAt,
    });
    return res.status(503).json({
      success: false,
      error: { code, message: err.message },
      request_id: requestId,
    });
  }

  const model = body.model || selectedProvider.defaultModel;
  metrics.providerRequestsTotal.inc({ provider: selectedProvider.name, model });

  const timer = metrics.providerRequestDurationSeconds.startTimer({
    provider: selectedProvider.name, model,
  });

  try {
    const result = await selectedProvider.execute({
      message,
      model,
      temperature: body.temperature,
      instruction: body.instruction,
    });
    timer();
    metrics.providerRequestsSuccessTotal.inc({ provider: selectedProvider.name, model });
    metrics.chatRequestsSuccessTotal.inc();

    const durationMs = Date.now() - startedAt;
    logger.info({
      request_id: requestId, provider: selectedProvider.name, model,
      operation: 'chat_execute', duration: durationMs, success: true,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model, success: true, durationMs,
    });

    return res.status(200).json({
      success: true,
      provider: selectedProvider.name,
      model: result.model || model,
      message,
      response: result.response,
      usage: result.usage || {},
      request_id: requestId,
    });
  } catch (err) {
    timer();
    const code = err.code || 'PROVIDER_EXECUTION_FAILED';
    metrics.providerRequestsFailedTotal.inc({ provider: selectedProvider.name, model, error_code: code });
    metrics.chatRequestsFailedTotal.inc();

    const durationMs = Date.now() - startedAt;
    logger.error({
      request_id: requestId, provider: selectedProvider.name, model,
      operation: 'chat_execute', duration: durationMs, success: false, error_code: code,
    });
    await db.recordRequest({
      requestId, provider: selectedProvider.name, model, success: false, errorCode: code, durationMs,
    });

    return res.status(502).json({
      success: false,
      error: { code, message: err.message },
      request_id: requestId,
    });
  }
});

module.exports = router;
