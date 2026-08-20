// PATCH_MARKER_GEMINI_PROVIDER_V1
const fetch = require('node-fetch');
const config = require('../lib/config');

class ProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// Gemini's generateContent API has no "system" role in contents[]; system
// messages are folded into a top-level systemInstruction instead, and
// "assistant" turns must be relabeled "model".
function toGeminiPayload(messages) {
  const contents = [];
  let systemInstruction;
  for (const m of messages) {
    if (m.role === 'system') {
      systemInstruction = systemInstruction ? `${systemInstruction}\n${m.content}` : m.content;
      continue;
    }
    contents.push({
      role: m.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: m.content }],
    });
  }
  return { contents, systemInstruction };
}

async function execute({ message, model, temperature, instruction, messages: structuredMessages, max_tokens }) {
  const apiKey = config.providers.gemini.apiKey;
  if (!apiKey) {
    throw new ProviderError('PROVIDER_NOT_CONFIGURED', 'Gemini API key is not configured');
  }

  const chosenModel = model || config.providers.gemini.defaultModel;

  // Same normalization contract as groq.js: structured messages[] (from
  // /v1/execute, or normalized by /v1/chat) take precedence over the legacy
  // {message, instruction} shape.
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

  const { contents, systemInstruction } = toGeminiPayload(messages);

  const requestBody = {
    contents,
    generationConfig: {
      temperature: typeof temperature === 'number' ? temperature : 0.3,
    },
  };
  if (systemInstruction) {
    requestBody.systemInstruction = { parts: [{ text: systemInstruction }] };
  }
  if (typeof max_tokens === 'number') {
    requestBody.generationConfig.maxOutputTokens = max_tokens;
  }

  const url = `${config.providers.gemini.baseUrl}/models/${encodeURIComponent(chosenModel)}:generateContent`;

  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify(requestBody),
      timeout: 20000,
    });
  } catch (err) {
    if (err.type === 'request-timeout') {
      throw new ProviderError('UPSTREAM_TIMEOUT', 'Gemini request timed out');
    }
    throw new ProviderError('PROVIDER_NETWORK_ERROR', `Failed to reach Gemini: ${err.message}`);
  }

  if (!response.ok) {
    let bodyText = '';
    try { bodyText = await response.text(); } catch (_) { /* ignore */ }
    if (response.status === 401 || response.status === 403) {
      throw new ProviderError('PROVIDER_AUTH_FAILED', 'Gemini rejected the API key');
    }
    if (response.status === 429) {
      throw new ProviderError('PROVIDER_RATE_LIMITED', 'Gemini rate limit exceeded');
    }
    if (response.status === 404 || (response.status === 400 && /model/i.test(bodyText))) {
      throw new ProviderError('MODEL_NOT_FOUND', `Gemini does not recognize model "${chosenModel}"`);
    }
    throw new ProviderError('PROVIDER_EXECUTION_FAILED', `Gemini returned status ${response.status}: ${bodyText.slice(0, 300)}`);
  }

  const data = await response.json();
  const candidate = data.candidates && data.candidates[0];
  const parts = candidate && candidate.content && candidate.content.parts;
  const text = Array.isArray(parts) ? parts.map((p) => p.text || '').join('') : '';

  const usage = data.usageMetadata
    ? {
      prompt_tokens: data.usageMetadata.promptTokenCount,
      completion_tokens: data.usageMetadata.candidatesTokenCount,
      total_tokens: data.usageMetadata.totalTokenCount,
    }
    : {};

  return {
    model: chosenModel,
    response: text,
    usage,
  };
}

async function healthCheck() {
  if (!config.providers.gemini.apiKey) {
    return { healthy: false, reason: 'not_configured' };
  }
  return { healthy: true };
}

module.exports = { execute, healthCheck, ProviderError };
