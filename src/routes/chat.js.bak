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

  try {
    const result = await executionService.runExecution({
      requestId,
      provider: body.provider,
      model: body.model,
      messages,
      temperature: body.temperature,
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
