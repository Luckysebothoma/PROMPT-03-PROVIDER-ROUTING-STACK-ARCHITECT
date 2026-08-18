const registry = require('../providers/registry');
const redisClient = require('./redisClient');

class RoutingError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * Deterministic provider resolution strategy:
 *   1. Explicit provider (must be implemented+enabled+configured, or error)
 *   2. Explicit model implies a provider only when provider is also given;
 *      otherwise model alone is not enough to infer a provider in Day 3.
 *   3. Automatic selection ("auto" or omitted provider): deterministic
 *      round-robin across implemented+enabled+configured providers.
 *   4. First healthy implemented provider (fallback if round-robin state
 *      is unavailable, e.g. Redis down).
 */
async function resolveProvider({ provider, model }) {
  const available = registry.implementedAvailableProviders();

  if (provider && provider !== 'auto') {
    const requested = registry.getProvider(provider);
    if (!requested) {
      throw new RoutingError('PROVIDER_NOT_FOUND', `Unknown provider: ${provider}`);
    }
    if (!requested.implemented) {
      throw new RoutingError('PROVIDER_NOT_IMPLEMENTED', `Provider not implemented: ${provider}`);
    }
    if (!requested.enabled) {
      throw new RoutingError('PROVIDER_DISABLED', `Provider disabled: ${provider}`);
    }
    if (!requested.configured) {
      throw new RoutingError('PROVIDER_NOT_CONFIGURED', `Provider not configured: ${provider}`);
    }
    return requested;
  }

  if (available.length === 0) {
    throw new RoutingError('PROVIDER_UNAVAILABLE', 'No available provider could execute this request');
  }

  // Automatic selection via deterministic round-robin (Redis-backed).
  try {
    const idx = await redisClient.nextRoutingIndex('routing:auto:cursor', available.length);
    return available[idx];
  } catch (_) {
    // Fallback: first healthy implemented provider.
    return available[0];
  }
}

module.exports = { resolveProvider, RoutingError };
