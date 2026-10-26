const fetch = require('node-fetch');
const config = require('../lib/config');
const keyPool = require('../lib/keyPool');

class ProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// Single attempt with one key + one model. Throws ProviderError with a code
// the caller uses to decide: rotate key, rotate model, or give up.
async function callGroq(apiKey, requestBody) {
  let response;
  try {
    response = await fetch(`${config.providers.groq.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(requestBody),
      timeout: 20000,
    });
  } catch (err) {
    if (err.type === 'request-timeout') throw new ProviderError('UPSTREAM_TIMEOUT', 'Groq request timed out');
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Groq: ${err.message}`);
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }

    if (response.status === 401 || response.status === 403) {
      throw new ProviderError('PROVIDER_AUTH_FAILED', 'Groq rejected the API key');
    }
    if (response.status === 429) {
      const err = new ProviderError('PROVIDER_RATE_LIMITED', 'Groq rate limit exceeded');
      err.retryAfter = parseInt(response.headers.get('retry-after'), 10) || 0;
      throw err;
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Groq does not recognize model "${requestBody.model}"`);
    }
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Groq returned status ${response.status}: ${bodyText.slice(0, 300)}`);
  }

  return response.json();
}

async function execute({ message, model, temperature, instruction, messages: structuredMessages, max_tokens }) {
  if (keyPool.count('groq') === 0) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'No GROQ_API_KEY_[1-N] configured');
  }

  let messages;
  if (Array.isArray(structuredMessages) && structuredMessages.length > 0) {
    messages = structuredMessages.map((m) => ({ role: m.role || 'user', content: m.content }));
  } else {
    messages = [];
    if (instruction) messages.push({ role: 'system', content: instruction });
    messages.push({ role: 'user', content: message });
  }

  const primary = model || config.providers.groq.defaultModel;
  const fallbacks = (config.providers.groq.fallbackModels || []).filter((m) => m !== primary);
  const modelsToTry = [primary, ...fallbacks];

  let lastError;

  for (const chosenModel of modelsToTry) {
    const requestBody = {
      model: chosenModel,
      messages,
      temperature: typeof temperature === 'number' ? temperature : 0.3,
    };
    if (typeof max_tokens === 'number') requestBody.max_tokens = max_tokens;

    // Try every non-cooled-down key for this model.
    for (const entry of keyPool.availableKeys('groq')) {
      try {
        const data = await callGroq(entry.key, requestBody);
        const choice = data.choices && data.choices[0];
        return {
          model: chosenModel,
          response: choice && choice.message && choice.message.content ? choice.message.content : '',
          usage: data.usage || {},
          keyId: entry.id, // handy for logging / mapping to teamId
        };
      } catch (err) {
        lastError = err;
        if (!(err instanceof ProviderError)) throw err;

        if (err.code === 'PROVIDER_RATE_LIMITED') {
          console.warn(`[groq] key _${entry.id} rate limited on ${chosenModel}, rotating`);
          keyPool.markLimited('groq', entry, err.retryAfter);
          continue; // next key
        }
        if (err.code === 'PROVIDER_AUTH_FAILED') {
          console.warn(`[groq] key _${entry.id} rejected, rotating`);
          keyPool.markDead('groq', entry);
          continue; // next key
        }
        if (err.code === 'MODEL_NOT_FOUND') break; // no point trying other keys, go to next model
        throw err; // timeouts, 5xx, network: not a key problem
      }
    }
  }

  // Everything exhausted
  if (lastError && lastError.code === 'MODEL_NOT_FOUND') throw lastError;
  throw new ProviderError(
    'PROVIDER_RATE_LIMITED',
    `All Groq keys/models exhausted (${keyPool.count('groq')} keys, ${modelsToTry.length} models)`
  );
}

async function healthCheck() {
  if (keyPool.count('groq') === 0) return { healthy: false, reason: 'not_configured' };
  const available = keyPool.availableKeys('groq').length;
  return { healthy: available > 0, keys: keyPool.count('groq'), available };
}

module.exports = { execute, healthCheck, ProviderError };