const fetch = require('node-fetch');
const config = require('../lib/config');

class ProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

async function execute({ message, model, temperature, instruction, messages: structuredMessages, max_tokens }) {
  const apiKey = config.providers.groq.apiKey;
  if (!apiKey) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'Groq API key is not configured');
  }

  const chosenModel = model || config.providers.groq.defaultModel;

  // Structured messages[] (from /v1/execute, or normalized by /v1/chat) take
  // precedence. The legacy {message, instruction} shape is preserved for any
  // direct callers that still use it.
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

  const requestBody = {
    model: chosenModel,
    messages,
    temperature: typeof temperature === 'number' ? temperature : 0.3,
  };
  if (typeof max_tokens === 'number') {
    requestBody.max_tokens = max_tokens;
  }

  let response;
  try {
    response = await fetch(`${config.providers.groq.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(requestBody),
      timeout: 20000,
    });
  } catch (err) {
    if (err.type === 'request-timeout') {
      throw new ProviderError('UPSTREAM_TIMEOUT', 'Groq request timed out');
    }
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Groq: ${err.message}`);
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }
    if (response.status === 401 || response.status === 403) {
      throw new ProviderError('PROVIDER_AUTH_FAILED', 'Groq rejected the API key');
    }
    if (response.status === 429) {
      throw new ProviderError('PROVIDER_RATE_LIMITED', 'Groq rate limit exceeded');
    }
    if (response.status >= 500) {
      throw new ProviderError('PROVIDER_UPSTREAM_5XX', 'Groq returned a temporary server error');
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Groq does not recognize model "${chosenModel}"`);
    }
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Groq returned status ${response.status}: ${bodyText.slice(0, 300)}`);
  }

  const data = await response.json();
  const choice = data.choices && data.choices[0];
  const text = choice && choice.message && choice.message.content ? choice.message.content : '';

  return {
    model: chosenModel,
    response: text,
    usage: data.usage || {},
  };
}

async function healthCheck() {
  if (!config.providers.groq.apiKey) {
    return { healthy: false, reason: 'not_configured' };
  }
  return { healthy: true };
}

module.exports = { execute, healthCheck, ProviderError };
