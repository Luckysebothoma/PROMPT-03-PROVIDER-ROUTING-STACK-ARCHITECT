'use strict';
// AIG_TELEMETRY_V1: Groq provider with key-pool rotation, model fallback and database telemetry.
const fetch = require('node-fetch');
const config = require('../lib/config');
const keyPool = require('../lib/keyPool');
const telemetry = require('../lib/telemetry');

class ProviderError extends Error {
  constructor(code, message, extra) {
    super(message);
    this.code = code;
    if (extra) Object.assign(this, extra);
  }
}

const TIMEOUT_MS = parseInt(process.env.GROQ_TIMEOUT_MS || '20000', 10);
const MAX_TOTAL_MS = parseInt(process.env.AIG_MAX_TOTAL_MS || '60000', 10);
let configSnapshotSent = false;

function envFallbackModels() {
  const fromCfg = (config.providers.groq && config.providers.groq.fallbackModels) || [];
  const fromEnv = (process.env.GROQ_FALLBACK_MODELS || '').split(',').map((s) => s.trim()).filter(Boolean);
  return [...fromCfg, ...fromEnv];
}

// One attempt with one key and one model. Throws ProviderError carrying status/headers/body for telemetry.
async function callGroq(apiKey, requestBody) {
  const gcfg = config.providers.groq;
  let response;
  try {
    response = await fetch(`${gcfg.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(requestBody),
      timeout: TIMEOUT_MS,
    });
  } catch (err) {
    if (err.type === 'request-timeout') throw new ProviderError('UPSTREAM_TIMEOUT', 'Groq request timed out', { timeout: true });
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Groq: ${err.message}`, { stack: err.stack });
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }
    const ra = parseFloat(response.headers.get('retry-after'));
    const extra = { status: response.status, headers: response.headers, bodyText, retryAfter: Number.isFinite(ra) ? ra : 0 };
    if (response.status === 401 || response.status === 403) throw new ProviderError('PROVIDER_AUTH_FAILED', 'Groq rejected the API key', extra);
    if (response.status === 429) throw new ProviderError('PROVIDER_RATE_LIMITED', 'Groq rate limit exceeded', extra);
    if (response.status === 413 || (response.status === 400 && /context (length|window)|too many tokens|maximum context|reduce the length/i.test(bodyText))) {
      throw new ProviderError('CONTEXT_TOO_LARGE', `Request exceeds context/token limits for "${requestBody.model}"`, extra);
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText) && !/image|vision/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Groq does not recognize model "${requestBody.model}"`, extra);
    }
<<<<<<< Updated upstream
    if (response.status >= 500) {
      throw new ProviderError('PROVIDER_UPSTREAM_5XX', 'Groq returned a temporary server error');
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Groq does not recognize model "${chosenModel}"`);
=======
    if (response.status === 400 && /image|vision|multimodal|modalit/i.test(bodyText)) {
      throw new ProviderError('UNSUPPORTED_MODALITY', `Model "${requestBody.model}" rejected image/multimodal input`, extra);
>>>>>>> Stashed changes
    }
    if (response.status >= 500) throw new ProviderError('PROVIDER_UNAVAILABLE', `Groq returned status ${response.status}`, extra);
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Groq returned status ${response.status}: ${bodyText.slice(0, 300)}`, extra);
  }

  let data;
  try { data = await response.json(); } catch (_) {
    throw new ProviderError('MALFORMED_RESPONSE', 'Groq returned a non-JSON body', { status: response.status, headers: response.headers });
  }
  if (!data || !Array.isArray(data.choices)) {
    throw new ProviderError('MALFORMED_RESPONSE', 'Groq response has no choices', { status: response.status, headers: response.headers });
  }
  return { data, headers: response.headers, status: response.status };
}

async function execute(opts = {}) {
  const { message, model, temperature, instruction, messages: structuredMessages, max_tokens } = opts;
  const gcfg = config.providers.groq;
  keyPool.setFallbackKey('groq', gcfg.apiKey);
  if (keyPool.count('groq') === 0) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'No GROQ_API_KEY / GROQ_API_KEY_[1-N] configured');
  }

  // Structured messages[] take precedence; legacy {message, instruction} is preserved.
  let messages;
  if (Array.isArray(structuredMessages) && structuredMessages.length > 0) {
    messages = structuredMessages.map((m) => ({ ...m, role: m.role || 'user', content: m.content }));
  } else {
    messages = [];
    if (instruction) messages.push({ role: 'system', content: instruction });
    messages.push({ role: 'user', content: message });
  }

  const primary = model || gcfg.defaultModel;
  const baseBody = { messages, temperature: typeof temperature === 'number' ? temperature : 0.3 };
  if (typeof max_tokens === 'number') baseBody.max_tokens = max_tokens;
  for (const k of ['top_p', 'seed', 'stop', 'tools', 'tool_choice', 'response_format']) if (opts[k] !== undefined && opts[k] !== null) baseBody[k] = opts[k];

  const vision = telemetry.hasImages(messages);
  const registry = await telemetry.loadRegistry('groq');
  if (!configSnapshotSent) {
    configSnapshotSent = true;
    telemetry.recordProviderConfig('groq', { base_url: gcfg.baseUrl, default_model: gcfg.defaultModel, fallback_models: envFallbackModels(), key_count: keyPool.count('groq') });
  }

  const estTokens = telemetry.estimateTokens(JSON.stringify(messages).length) + (typeof max_tokens === 'number' ? max_tokens : 0);
  const usable = (m) => {
    const row = registry.get(m);
    if (!row) return true;
    if (row.enabled === false || row.active === false || row.availability === 'unavailable') return false;
    if (vision && row.supports_vision === false) return false;
    if (row.context_window && estTokens > row.context_window) return false;
    return true;
  };
  const dbFallbacks = [...registry.values()].filter((r) => r.fallback_eligible && r.enabled && r.active)
    .sort((a, b) => (a.fallback_priority - b.fallback_priority) || (a.priority - b.priority)).map((r) => r.model_id);
  let candidates = [...new Set([primary, ...envFallbackModels(), ...dbFallbacks])].filter(Boolean).filter(usable);
  if (!candidates.length) candidates = [primary];

  const t = telemetry.startInteraction({
    provider: 'groq', endpoint: '/chat/completions', requestedModel: primary, ctx: opts, messages,
    params: { temperature: baseBody.temperature, max_tokens: baseBody.max_tokens, top_p: baseBody.top_p, seed: baseBody.seed, stop: baseBody.stop, tools: baseBody.tools, response_format: baseBody.response_format },
    requestType: vision ? 'vision' : 'chat',
  });

  const t0 = Date.now();
  let lastError = null;
  let minRetry = 0;

  outer:
  for (const chosenModel of candidates) {
    const keys = keyPool.availableKeys('groq', chosenModel);
    if (!keys.length) {
      const wait = Math.ceil(keyPool.nextAvailableInMs('groq', chosenModel) / 1000);
      lastError = lastError || new ProviderError('PROVIDER_RATE_LIMITED', `All Groq keys are cooling down for ${chosenModel}`, { retryAfter: wait });
      continue;
    }
    for (const entry of keys) {
      if (Date.now() - t0 > MAX_TOTAL_MS) break outer;
      const started = Date.now();
      const ref = keyPool.keyRef('groq', entry);
      try {
        const { data, headers, status } = await callGroq(entry.key, { ...baseBody, model: chosenModel });
        const choice = data.choices[0] || {};
        const text = choice.message && choice.message.content ? choice.message.content : '';
        const usage = data.usage || {};
        const cachedPresent = usage.prompt_tokens_details && typeof usage.prompt_tokens_details.cached_tokens === 'number';
        t.addAttempt({
          provider: 'groq', model: chosenModel, keyRef: ref, startedAt: started, durationMs: Date.now() - started, httpStatus: status, success: true,
          headers, usage, responseText: text, toolCalls: choice.message && choice.message.tool_calls, finishReason: choice.finish_reason,
          systemFingerprint: data.system_fingerprint, providerRequestId: data.x_groq && data.x_groq.id, cacheRequested: !!opts.cache || cachedPresent,
          providerMetadata: { id: data.id, model: data.model, x_groq: data.x_groq, service_tier: data.service_tier },
        });
        keyPool.markGood('groq', entry);
        t.finish({ success: true, finalProvider: 'groq', finalModel: chosenModel });
        const result = { model: chosenModel, response: text, usage, keyId: entry.id, request_id: t.requestId };
        if (choice.message && choice.message.tool_calls) result.tool_calls = choice.message.tool_calls;
        if (choice.finish_reason) result.finish_reason = choice.finish_reason;
        return result;
      } catch (err) {
        if (!(err instanceof ProviderError)) {
          t.addAttempt({ provider: 'groq', model: chosenModel, keyRef: ref, startedAt: started, durationMs: Date.now() - started, success: false, error: err });
          t.finish({ success: false, error: err });
          throw err;
        }
        t.addAttempt({ provider: 'groq', model: chosenModel, keyRef: ref, startedAt: started, durationMs: Date.now() - started, success: false, error: err, httpStatus: err.status, headers: err.headers });
        lastError = err;

        if (err.code === 'PROVIDER_RATE_LIMITED') {
          console.warn(`[groq] key ${ref} rate limited on ${chosenModel}; rotating`);
          keyPool.markLimited('groq', entry, chosenModel, err.retryAfter);
          if (err.retryAfter) minRetry = minRetry ? Math.min(minRetry, err.retryAfter) : err.retryAfter;
          continue; // next key
        }
        if (err.code === 'PROVIDER_AUTH_FAILED') {
          console.warn(`[groq] key ${ref} rejected; rotating`);
          keyPool.markDead('groq', entry);
          continue; // next key
        }
        if (['MODEL_NOT_FOUND', 'CONTEXT_TOO_LARGE', 'UNSUPPORTED_MODALITY', 'UPSTREAM_TIMEOUT', 'PROVIDER_NETWORK_ERROR', 'PROVIDER_UNAVAILABLE', 'MALFORMED_RESPONSE'].includes(err.code)) {
          break; // not a key problem: move to the next model
        }
        t.finish({ success: false, error: err }); // non-recoverable (e.g. other 4xx)
        throw err;
      }
    }
  }

  let finalErr = lastError;
  if (!finalErr) finalErr = new ProviderError('PROVIDER_EXECUTION_FAILED', 'No Groq model/key could be attempted');
  else if (finalErr.code === 'PROVIDER_RATE_LIMITED') {
    finalErr = new ProviderError('PROVIDER_RATE_LIMITED', `All Groq keys/models exhausted (${keyPool.count('groq')} keys, ${candidates.length} models)`, { retryAfter: minRetry || finalErr.retryAfter || 0, status: 429 });
  }
  t.finish({ success: false, error: finalErr });
  throw finalErr;
}

async function healthCheck() {
  const gcfg = config.providers.groq;
  keyPool.setFallbackKey('groq', gcfg && gcfg.apiKey);
  const total = keyPool.count('groq');
  if (total === 0) return { healthy: false, reason: 'not_configured' };
  const available = keyPool.availableKeys('groq', gcfg.defaultModel).length;
  return { healthy: available > 0, keys: total, available };
}

module.exports = { execute, healthCheck, ProviderError };
