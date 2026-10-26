
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const executionService = require('../lib/executionService');
const metrics = require('../lib/metrics');

const router = express.Router();

async function handleChat(req, res, forcedProvider = null) {
  const requestId = req.headers['x-request-id'] || uuidv4();
  res.setHeader('X-Request-ID', requestId);

  metrics.chatRequestsTotal.inc();

  const body = req.body || {};
  const message = body.message;

  if (!message || typeof message !== 'string') {
    metrics.chatRequestsFailedTotal.inc();
    return res.status(400).json({
      success: false,
      error: {
        code: 'INVALID_REQUEST',
        message: '"message" is required and must be a string',
      },
      request_id: requestId,
    });
  }

  const messages = [];

  if (body.instruction) {
    messages.push({
      role: 'system',
      content: body.instruction,
    });
  }

  messages.push({
    role: 'user',
    content: message,
  });

  const capability = body.capability || body.intent;

  try {
    const result = await executionService.runExecution({
      requestId,
      // Dedicated endpoints always use their designated provider.
      provider: forcedProvider || body.provider,
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

    return res.status(err.status || 502).json({
      success: false,
      error: {
        code: err.code || 'PROVIDER_EXECUTION_FAILED',
        message: err.message,
      },
      request_id: requestId,
    });
  }
}

// Existing provider-neutral endpoint: behavior remains unchanged.
router.post('/v1/chat', (req, res) => handleChat(req, res));

// Dedicated provider endpoints.
router.post('/v1/chat/groq', (req, res) =>
  handleChat(req, res, 'groq')
);

router.post('/v1/chat/gemini', (req, res) =>
  handleChat(req, res, 'gemini')
);

module.exports = router;
