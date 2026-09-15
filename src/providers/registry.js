// PATCH_MARKER_REGISTRY_CAPABILITIES_V2
const config = require('../lib/config');
const groq = require('./groq');
const gemini = require('./gemini');

// Provider registry describing state: implemented / enabled / configured / healthy.
// Each provider also carries a `models` catalog (model id -> capability tags)
// so the router can pick a worker by capability/intent, not just by name.
function buildRegistry() {
  return {
    groq: {
      name: 'groq',
      implemented: config.providers.groq.implemented,
      enabled: config.providers.groq.enabled,
      configured: Boolean(config.providers.groq.apiKey),
      defaultModel: config.providers.groq.defaultModel,
      models: config.providers.groq.models,
      execute: groq.execute,
      healthCheck: groq.healthCheck,
    },
    gemini: {
      name: 'gemini',
      implemented: config.providers.gemini.implemented,
      enabled: config.providers.gemini.enabled,
      configured: Boolean(config.providers.gemini.apiKey),
      defaultModel: config.providers.gemini.defaultModel,
      models: config.providers.gemini.models,
      execute: gemini.execute,
      healthCheck: gemini.healthCheck,
    },
  };
}

function publicProviderList() {
  const reg = buildRegistry();
  return Object.values(reg).map((p) => ({
    name: p.name,
    implemented: p.implemented,
    enabled: p.enabled,
    configured: p.configured,
    defaultModel: p.defaultModel,
    models: Object.entries(p.models || {}).map(([id, meta]) => ({
      id,
      capabilities: meta.capabilities || [],
      maxCompletionTokens: typeof meta.maxCompletionTokens === 'number' ? meta.maxCompletionTokens : null,
      contextWindow: typeof meta.contextWindow === 'number' ? meta.contextWindow : null,
      preview: Boolean(meta.preview),
    })),
  }));
}

function implementedAvailableProviders() {
  const reg = buildRegistry();
  return Object.values(reg).filter((p) => p.implemented && p.enabled && p.configured);
}

function getProvider(name) {
  const reg = buildRegistry();
  return reg[name] || null;
}

// Flat list of every (provider, model) pair the registry knows about,
// regardless of current availability — used to answer "what could serve
// this capability" (GET /capabilities) as well as to drive routing.
function listWorkers() {
  const reg = buildRegistry();
  const workers = [];
  for (const p of Object.values(reg)) {
    if (!p.implemented) continue;
    for (const [modelId, meta] of Object.entries(p.models || {})) {
      workers.push({
        provider: p.name,
        model: modelId,
        capabilities: meta.capabilities || [],
        maxCompletionTokens: typeof meta.maxCompletionTokens === 'number' ? meta.maxCompletionTokens : null,
        available: Boolean(p.enabled && p.configured),
      });
    }
  }
  return workers;
}

function workersForCapability(capability) {
  return listWorkers().filter((w) => w.capabilities.includes(capability));
}

// Full model metadata (capabilities, maxCompletionTokens, contextWindow,
// preview, ...) for one resolved (provider, model) pair — lets callers like
// executionService cap max_tokens against what's actually configured for
// that model without re-deriving it from buildRegistry() themselves.
function modelConfig(providerName, modelId) {
  const reg = buildRegistry();
  const p = reg[providerName];
  if (!p || !p.models) return null;
  return p.models[modelId] || null;
}

function allCapabilities() {
  const set = new Set();
  for (const w of listWorkers()) {
    for (const c of w.capabilities) set.add(c);
  }
  return Array.from(set).sort();
}

module.exports = {
  buildRegistry,
  publicProviderList,
  implementedAvailableProviders,
  getProvider,
  listWorkers,
  workersForCapability,
  allCapabilities,
  modelConfig,
};
