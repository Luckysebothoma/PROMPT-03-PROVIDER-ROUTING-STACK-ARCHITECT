'use strict';
// Ollama local inference adapter using Ollama's OpenAI-compatible API.
const fetch = require('node-fetch');
const config = require('../lib/config');

class ProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

async function execute({ messages, model, temperature, max_tokens }) {
  const provider = config.providers.ollama;
  if (!provider.enabled || !provider.baseUrl) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'Ollama is disabled or OLLAMA_BASE_URL is missing');
  }
  const chosenModel = model || provider.defaultModel;
  if (!chosenModel) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'Set OLLAMA_DEFAULT_MODEL to an installed Ollama model');
  }

  const requestBody = { model: chosenModel, messages, stream: false };
  const options = {};
  if (typeof temperature === 'number') options.temperature = temperature;
  if (typeof max_tokens === 'number') options.num_predict = max_tokens;
  if (Object.keys(options).length) requestBody.options = options;

  let response;
  try {
    response = await fetch(`${provider.baseUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(requestBody),
      timeout: parseInt(process.env.OLLAMA_TIMEOUT_MS || '120000', 10),
    });
  } catch (err) {
    if (err.type === 'request-timeout') {
      throw new ProviderError('UPSTREAM_TIMEOUT', 'Ollama request timed out');
    }
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Ollama: ${err.message}`);
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }
    if (response.status === 404 || /model.*(not found|does not exist)/i.test(bodyText)) {
      throw new ProviderError('MODEL_NOT_FOUND', `Ollama model "${chosenModel}" was not found`);
    }
    if (response.status === 429) {
      throw new ProviderError('PROVIDER_RATE_LIMITED', 'Ollama is busy or rate limited');
    }
    if (response.status >= 500) {
      throw new ProviderError('PROVIDER_UPSTREAM_5XX', `Ollama returned status ${response.status}`);
    }
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Ollama returned status ${response.status}: ${bodyText.slice(0, 300)}`);
  }

  const data = await response.json();
  const choice = data.choices && data.choices[0];
  const text = choice && choice.message && choice.message.content;
  if (typeof text !== 'string') {
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', 'Ollama returned an empty or unrecognized chat response');
  }
  return {
    model: data.model || chosenModel,
    response: text,
    usage: {
      prompt_tokens: data.usage && data.usage.prompt_tokens,
      completion_tokens: data.usage && data.usage.completion_tokens,
      total_tokens: data.usage && data.usage.total_tokens,
    },
  };
}

async function healthCheck() {
  const baseUrl = config.providers.ollama.baseUrl;
  try {
    const response = await fetch(`${baseUrl}/api/tags`, { timeout: 5000 });
    if (!response.ok) return { healthy: false, reason: `http_${response.status}` };
    return { healthy: true };
  } catch (err) {
    return { healthy: false, reason: err.type === 'request-timeout' ? 'timeout' : 'unreachable' };
  }
}

module.exports = { execute, healthCheck, ProviderError };
