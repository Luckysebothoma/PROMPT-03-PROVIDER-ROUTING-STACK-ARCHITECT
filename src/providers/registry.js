const config = require('../lib/config');
const groq = require('./groq');

// Provider registry describing state: implemented / enabled / configured / healthy.
// This mirrors the contract established by Stack 2's provider registry, extended
// with an "implemented" flag and an execute() function for Stack 3 routing.
function buildRegistry() {
  return {
    groq: {
      name: 'groq',
      implemented: config.providers.groq.implemented,
      enabled: config.providers.groq.enabled,
      configured: Boolean(config.providers.groq.apiKey),
      defaultModel: config.providers.groq.defaultModel,
      execute: groq.execute,
      healthCheck: groq.healthCheck,
    },
    gemini: {
      name: 'gemini',
      implemented: false, // NOT implemented in Day 3 - registry-only entry
      enabled: config.providers.gemini.enabled,
      configured: Boolean(config.providers.gemini.apiKey),
      defaultModel: config.providers.gemini.defaultModel,
      execute: null,
      healthCheck: async () => ({ healthy: false, reason: 'not_implemented' }),
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

module.exports = { buildRegistry, publicProviderList, implementedAvailableProviders, getProvider };
