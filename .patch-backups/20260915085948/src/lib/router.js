// PATCH_MARKER_ROUTER_CAPABILITIES_V2

const registry = require('../providers/registry');
const redisClient = require('./redisClient');

class RoutingError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * Env-driven capability defaults. These give a deterministic, zero-Redis
 * fast path for the two capabilities we care about most, while still
 * falling through to the generic worker/round-robin logic for anything
 * else (or if the preferred provider isn't actually usable right now).
 *
 *   chat  -> groq   (GROQ_DEFAULT_MODEL)
 *   image -> gemini (GEMINI_DEFAULT_MODEL)
 *
 * Add more entries here as new capabilities/providers come online —
 * no other code path needs to change.
 */
const CAPABILITY_PROVIDER_DEFAULTS = {
  chat: {
    providerName: 'groq',
    model: process.env.GROQ_DEFAULT_MODEL,
  },
  image: {
    providerName: 'gemini',
    model: process.env.GEMINI_DEFAULT_MODEL,
  },
};

const DEFAULT_CAPABILITY = 'chat';

/**
 * A provider is only usable if the registry has it, it's implemented,
 * enabled, and configured (i.e. has whatever API key/env it needs).
 */
function isUsable(providerEntry) {
  return Boolean(
    providerEntry &&
      providerEntry.implemented &&
      providerEntry.enabled &&
      providerEntry.configured
  );
}

/**
 * Deterministic provider (+ optional model) resolution strategy:
 *
 *   1. Explicit provider (must be implemented+enabled+configured, or error).
 *      An explicit model, if also given, is honored as-is.
 *
 *   2. No explicit provider: resolve an effective capability — the one
 *      passed in, or DEFAULT_CAPABILITY ('chat') if omitted — and check
 *      CAPABILITY_PROVIDER_DEFAULTS for an env-configured provider/model
 *      for it. If that provider is currently usable, use it directly.
 *      This is what sends 'chat' to groq and 'image' to gemini by default.
 *
 *   3. If there's no env default for the capability, or the env-default
 *      provider isn't usable right now, fall back to matching workers
 *      advertising that capability tag, restricted to
 *      implemented+enabled+configured providers, with deterministic
 *      Redis-backed round-robin across matches.
 *
 *   4. Automatic selection ("auto", omitted provider, or an unmatched
 *      capability): deterministic Redis-backed round-robin across all
 *      implemented+enabled+configured providers, using each provider's
 *      default model.
 *
 *   5. Fallback: first healthy implemented provider (used if Redis is
 *      unavailable at any of the steps above).
 *
 * Returns { provider, model } — model may be undefined, in which case the
 * caller (executionService) falls back to provider.defaultModel.
 */
async function resolveProvider({ provider, model, capability }) {
  // 1. Explicit provider wins outright.
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

  // 2. Env-driven capability default (fast path, no Redis round-robin).
  const effectiveCapability = capability || DEFAULT_CAPABILITY;
  const capabilityDefault = CAPABILITY_PROVIDER_DEFAULTS[effectiveCapability];

  if (capabilityDefault && !model) {
    const defaultProvider = registry.getProvider(capabilityDefault.providerName);
    if (isUsable(defaultProvider)) {
      return { provider: defaultProvider, model: capabilityDefault.model };
    }
    // Preferred provider for this capability isn't usable (disabled,
    // unconfigured, not implemented) — fall through to steps 3/4 rather
    // than erroring, since capability defaults are a preference, not a
    // hard requirement.
  }

  // 3. Generic capability-tagged worker matching, if any advertise it.
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

  // 4. Auto round-robin across everything usable.
  const available = registry.implementedAvailableProviders();
  if (available.length === 0) {
    throw new RoutingError('PROVIDER_UNAVAILABLE', 'No available provider could execute this request');
  }

  try {
    const idx = await redisClient.nextRoutingIndex('routing:auto:cursor', available.length);
    return { provider: available[idx], model };
  } catch (_) {
    // 5. Fallback: first healthy implemented provider.
    return { provider: available[0], model };
  }
}

module.exports = { resolveProvider, RoutingError, CAPABILITY_PROVIDER_DEFAULTS };