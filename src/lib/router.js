// PATCH_MARKER_ROUTER_CAPABILITIES_V1
const registry = require('../providers/registry');
const redisClient = require('./redisClient');

class RoutingError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * Deterministic provider (+ optional model) resolution strategy:
 *   1. Explicit provider (must be implemented+enabled+configured, or error).
 *      An explicit model, if also given, is honored as-is.
 *   2. No explicit provider, but a capability/intent hint is given: pick a
 *      worker (provider+model) whose capability tags include it, restricted
 *      to implemented+enabled+configured providers. Deterministic
 *      round-robin (Redis-backed) across matching workers. If no worker
 *      matches the capability, this falls through to step 3 rather than
 *      erroring — capability hints are a routing preference, not a
 *      hard requirement.
 *   3. Automatic selection ("auto", omitted provider, or an unmatched
 *      capability): deterministic Redis-backed round-robin across all
 *      implemented+enabled+configured providers, using each provider's
 *      default model.
 *   4. Fallback: first healthy implemented provider (used if Redis is
 *      unavailable at any of the steps above).
 *
 * Returns { provider, model } — model may be undefined, in which case the
 * caller (executionService) falls back to provider.defaultModel.
 */
async function resolveProvider({ provider, model, capability }) {
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
    return { provider: requested, model };
  }

  if (!model && capability) {
    const candidates = registry.workersForCapability(capability).filter((w) => w.available);
    if (candidates.length > 0) {
      let idx = 0;
      try {
        idx = await redisClient.nextRoutingIndex(`routing:capability:${capability}:cursor`, candidates.length);
      } catch (_) {
        idx = 0;
      }
      const chosen = candidates[idx];
      return { provider: registry.getProvider(chosen.provider), model: chosen.model };
    }
    // No worker advertises this capability right now — fall through to
    // generic auto-selection below rather than failing the request.
  }

  const available = registry.implementedAvailableProviders();
  if (available.length === 0) {
    throw new RoutingError('PROVIDER_UNAVAILABLE', 'No available provider could execute this request');
  }

  try {
    const idx = await redisClient.nextRoutingIndex('routing:auto:cursor', available.length);
    return { provider: available[idx], model };
  } catch (_) {
    // Fallback: first healthy implemented provider.
    return { provider: available[0], model };
  }
}

module.exports = { resolveProvider, RoutingError };
