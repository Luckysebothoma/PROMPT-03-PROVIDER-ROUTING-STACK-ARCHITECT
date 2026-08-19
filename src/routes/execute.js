// PATCH_MARKER_EXECUTE_ROUTE_V1
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const executionService = require('../lib/executionService');
const metrics = require('../lib/metrics');

const router = express.Router();

// POST /v1/execute - provider-neutral execution contract consumed by
// upstream orchestration (Stack 5). Stack 5 has already decided which
// worker/provider/model to use; this endpoint validates the request,
// resolves the provider through the same routing layer as /v1/chat,
// executes it, and returns a normalized, provider-neutral result.
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

  try {
    executionService.validateMessages(messages);
    executionService.validateOptionalNumber(temperature, 'temperature');
    executionService.validateOptionalNumber(max_tokens, 'max_tokens');
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
      requestId, provider, model, messages, temperature, max_tokens,
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
