require('dotenv').config();

function bool(v, def = false) {
  if (v === undefined || v === null || v === '') return def;
  return String(v).toLowerCase() === 'true';
}

// Capability tags let the router pick a worker (provider+model) by what the
// caller needs ("chat", "reasoning", "vision", ...) instead of a hardcoded
// provider name. A model may carry more than one tag. Tags are intentionally
// coarse-grained; refine per your own traffic once you have data.
const GROQ_MODELS = {
  'openai/gpt-oss-20b': { capabilities: ['chat', 'tool-use', 'fast'] },
  'openai/gpt-oss-120b': { capabilities: ['chat', 'reasoning', 'code', 'tool-use'] },
  // PREVIEW MODEL on Groq — eligible for evaluation only, not production;
  // Groq can discontinue preview models without notice. Keep 'implemented: true'
  // only if your router has a fallback path when this one disappears.
  'qwen/qwen3.6-27b': { capabilities: ['chat', 'vision', 'multimodal', 'reasoning', 'code', 'tool-use'], preview: true },
};

const GEMINI_MODELS = {
  'gemini-3.5-flash-lite': { capabilities: ['chat', 'classification', 'tool-use', 'fast'] },
  'gemini-3.6-flash': { capabilities: ['chat', 'reasoning', 'tool-use', 'code', 'multimodal'] },
  // NOTE: no free tier for this model in the Gemini API (Flash/Flash-Lite only
  // are free). Route here only if your Gemini credential has billing enabled.
  'gemini-3.1-pro-preview': { capabilities: ['chat', 'reasoning', 'tool-use', 'long_context', 'multimodal'] },
};

// --- Optional JSON-driven overrides -----------------------------------------
// AI_PROVIDERS_JSON / AI_MODELS_JSON / AI_CREDENTIALS_JSON let ops tune a
// provider's model catalog, default model, priority/weight, and credential
// rotation purely via .env — no code change needed to adjust defaults.
//
// Each JSON env is optional and independent, and applies PER PROVIDER ID:
// if AI_MODELS_JSON has entries for "gemini" but not "groq", only gemini's
// model catalog is overridden — groq keeps using GROQ_MODELS/GROQ_* env vars
// above exactly as before. A provider id that isn't "groq" or "gemini" is
// parsed but ignored (logged once) — registry.js only has execute()/
// healthCheck() adapters for those two today; a third provider needs its
// own adapter before these envs can make it live.
function parseJsonArrayEnv(name) {
  const raw = process.env[name];
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error('not an array');
    return parsed;
  } catch (err) {
    console.warn(`[config] ${name} is not a valid JSON array — ignoring (${err.message})`);
    return [];
  }
}

const AI_PROVIDERS_JSON = parseJsonArrayEnv('AI_PROVIDERS_JSON');
const AI_MODELS_JSON = parseJsonArrayEnv('AI_MODELS_JSON');
const AI_CREDENTIALS_JSON = parseJsonArrayEnv('AI_CREDENTIALS_JSON');

for (const p of AI_PROVIDERS_JSON) {
  if (!['groq', 'gemini', 'ollama'].includes(p.id)) {
    console.warn(
      `[config] AI_PROVIDERS_JSON has provider "${p.id}" but registry.js only ` +
      `implements groq/gemini — ignoring until an execute() adapter exists for it.`
    );
  }
}

function jsonModelsForProvider(providerId) {
  return AI_MODELS_JSON
    .filter((m) => m.provider === providerId && m.enabled !== false)
    .sort((a, b) => (b.priority || 0) - (a.priority || 0));
}

// Highest-priority enabled credential for `providerId` whose secret_env
// actually resolves to a non-empty value. Returns undefined if
// AI_CREDENTIALS_JSON has no entry for this provider at all — that's the
// signal for applyJsonOverrides() to keep the provider's own apiKey default
// (e.g. GEMINI_API_KEY) instead of treating it as "explicitly blank".
function jsonApiKeyForProvider(providerId) {
  const entry = AI_CREDENTIALS_JSON.find((c) => c.provider === providerId);
  if (!entry) return undefined;
  const candidates = (entry.credentials || [])
    .filter((c) => c.enabled !== false)
    .sort((a, b) => (b.priority || 0) - (a.priority || 0));
  for (const cred of candidates) {
    const value = process.env[cred.secret_env];
    if (value) return value;
  }
  return ''; // entry exists but no credential resolved -> explicitly not configured
}

// Layers AI_MODELS_JSON / AI_PROVIDERS_JSON / AI_CREDENTIALS_JSON overrides
// on top of one provider's hardcoded defaults. Any override this provider
// doesn't have JSON for falls through unchanged.
function applyJsonOverrides(providerId, hardcoded) {
  let models = hardcoded.models;
  let defaultModel = hardcoded.defaultModel;

  const jsonModels = jsonModelsForProvider(providerId);
  if (jsonModels.length > 0) {
    models = {};
    for (const m of jsonModels) {
      models[m.model] = {
        capabilities: m.capabilities || [],
        // lifecycle values seen in the wild: "stable", "preview", "beta",
        // "deprecated" — treat anything that isn't explicitly "stable" as
        // preview-grade for the stability ranking in buildCapabilityRouting.
        preview: Boolean(m.lifecycle) && m.lifecycle !== 'stable',
        priority: m.priority,
        weight: m.weight,
        contextWindow: m.context_window,
        maxCompletionTokens: m.max_completion_tokens,
        modalities: m.modalities,
      };
    }
    defaultModel = jsonModels[0].model; // already sorted by priority desc
  }

  const providerMeta = AI_PROVIDERS_JSON.find((p) => p.id === providerId);
  const enabled = providerMeta ? providerMeta.enabled !== false : hardcoded.enabled;
  const priority = providerMeta ? providerMeta.priority : undefined;
  const weight = providerMeta ? providerMeta.weight : undefined;

  const jsonApiKey = jsonApiKeyForProvider(providerId);
  const apiKey = jsonApiKey !== undefined ? jsonApiKey : hardcoded.apiKey;

  return { ...hardcoded, models, defaultModel, enabled, priority, weight, apiKey };
}

// --- Capability-based routing defaults --------------------------------------
// Auto-routing (router.js) needs to know, for every capability tag that
// actually appears in GROQ_MODELS/GEMINI_MODELS above, which provider (and
// which specific model) should serve it by default when a caller asks by
// capability instead of by provider name.
//
// This is computed from the model catalogs themselves — not hand-typed — so
// it can never drift out of sync with what's actually advertised (the old
// hardcoded `image -> gemini` mapping was exactly this kind of drift: no
// model anywhere is tagged "image", only "vision"/"multimodal", so that
// fast path was silently dead code).
//
// Override any single capability's provider via .env without touching code:
//   ROUTING_CHAT_PROVIDER=groq
//   ROUTING_VISION_PROVIDER=groq
//   ROUTING_MULTIMODAL_PROVIDER=gemini
// An override is honored only if that provider actually has a model
// advertising the capability; otherwise it's ignored (logged once at
// startup) and PROVIDER_PRIORITY below decides instead.
const PROVIDER_PRIORITY = ['groq', 'gemini', 'ollama'];

function envKeyForCapability(capability) {
  // tool-use -> ROUTING_TOOL_USE_PROVIDER, long_context -> ROUTING_LONG_CONTEXT_PROVIDER
  return `ROUTING_${capability.toUpperCase().replace(/-/g, '_')}_PROVIDER`;
}

function firstModelWithCapability(providerConfig, capability) {
  const matches = Object.entries(providerConfig.models || {}).filter(
    ([, meta]) => (meta.capabilities || []).includes(capability)
  );
  // Prefer a stable (non-preview) match; only fall back to a preview model
  // if that's the only thing this provider has for the capability.
  const stable = matches.find(([, meta]) => !meta.preview);
  const chosen = stable || matches[0];
  return chosen ? chosen[0] : providerConfig.defaultModel; // fallback shouldn't happen if candidates are correct
}

// True if `providerConfig` has at least one non-preview model advertising
// `capability`. Used to rank a provider with a GA model above a provider
// whose only option is a preview model (which the upstream vendor can pull
// without notice) — even when the preview-only provider is earlier in
// PROVIDER_PRIORITY.
function hasStableModelForCapability(providerConfig, capability) {
  return Object.values(providerConfig.models || {}).some(
    (meta) => (meta.capabilities || []).includes(capability) && !meta.preview
  );
}

function buildCapabilityRouting(providersConfig) {
  // capability -> ordered list of providers that actually advertise it,
  // in PROVIDER_PRIORITY order (ties broken later by stability).
  const candidatesByCapability = {};
  for (const providerName of PROVIDER_PRIORITY) {
    const p = providersConfig[providerName];
    if (!p) continue;
    for (const meta of Object.values(p.models || {})) {
      for (const capability of meta.capabilities || []) {
        if (!candidatesByCapability[capability]) candidatesByCapability[capability] = [];
        if (!candidatesByCapability[capability].includes(providerName)) {
          candidatesByCapability[capability].push(providerName);
        }
      }
    }
  }

  // Within each capability, sort candidates so any provider with a stable
  // (non-preview) model for that capability comes before one whose only
  // model for it is preview-only. PROVIDER_PRIORITY order is preserved as
  // the tie-break within each stability tier.
  for (const [capability, candidates] of Object.entries(candidatesByCapability)) {
    candidates.sort((a, b) => {
      const aStable = hasStableModelForCapability(providersConfig[a], capability);
      const bStable = hasStableModelForCapability(providersConfig[b], capability);
      if (aStable === bStable) return 0; // preserves original (PROVIDER_PRIORITY) order — Array#sort is stable
      return aStable ? -1 : 1;
    });
  }

  const routing = {};
  const warnings = [];
  for (const [capability, candidates] of Object.entries(candidatesByCapability)) {
    const overrideKey = envKeyForCapability(capability);
    const override = process.env[overrideKey];
    let providerName;
    if (override) {
      if (candidates.includes(override)) {
        providerName = override;
      } else {
        warnings.push(
          `${overrideKey}=${override} ignored: ${override} has no model advertising "${capability}" ` +
          `(eligible: ${candidates.join(', ')}). Using default instead.`
        );
        providerName = candidates[0];
      }
    } else {
      providerName = candidates[0];
    }
    routing[capability] = {
      providerName,
      model: firstModelWithCapability(providersConfig[providerName], capability),
    };
  }
  return { routing, warnings };
}

const providers = {
  groq: applyJsonOverrides('groq', {
    apiKey: process.env.GROQ_API_KEY || '',
    // llama-3.1-8b-instant / llama-3.3-70b-versatile were retired by Groq
    // (shutdown Aug 16, 2026) — openai/gpt-oss-20b is the recommended
    // successor and stays fast + cheap for general chat.
    defaultModel: process.env.GROQ_DEFAULT_MODEL || 'openai/gpt-oss-20b',
    enabled: bool(process.env.GROQ_ENABLED, true),
    baseUrl: process.env.GROQ_BASE_URL || 'https://api.groq.com/openai/v1',
    implemented: true,
    models: GROQ_MODELS,
  }),
  gemini: applyJsonOverrides('gemini', {
    apiKey: process.env.GEMINI_API_KEY || '',
    // gemini-1.5-flash is fully retired. gemini-3.6-flash is the current
    // GA workhorse (coding/agentic, good price/perf).
    defaultModel: process.env.GEMINI_DEFAULT_MODEL || 'gemini-3.6-flash',
    enabled: bool(process.env.GEMINI_ENABLED, true),
    baseUrl: process.env.GEMINI_BASE_URL || 'https://generativelanguage.googleapis.com/v1beta',
    implemented: true,
    models: GEMINI_MODELS,
  }),
};

// Ollama exposes an OpenAI-compatible /v1/chat/completions endpoint.
// Keep its model catalog explicit: only advertise models configured by the operator.
const OLLAMA_MODELS = (process.env.OLLAMA_MODELS || '')
  .split(',').map((s) => s.trim()).filter(Boolean)
  .reduce((catalog, model) => {
    catalog[model] = { capabilities: ['chat'] };
    return catalog;
  }, {});

providers.ollama = applyJsonOverrides('ollama', {
  apiKey: '',
  defaultModel: process.env.OLLAMA_DEFAULT_MODEL || Object.keys(OLLAMA_MODELS)[0] || '',
  enabled: bool(process.env.OLLAMA_ENABLED, true),
  baseUrl: (process.env.OLLAMA_BASE_URL || 'http://127.0.0.1:11434').replace(/\\/$/, ''),
  implemented: true,
  models: OLLAMA_MODELS,
});

const capabilityRouting = buildCapabilityRouting(providers);

module.exports = {
  port: parseInt(process.env.PORT || '8080', 10),
  serviceName: process.env.SERVICE_NAME || 'ai-gateway-3-of-10-provider-routing',
  nodeEnv: process.env.NODE_ENV || 'production',

  postgres: {
    host: process.env.POSTGRES_HOST || 'postgres',
    port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    database: process.env.POSTGRES_DB || 'ai_gateway_routing',
    user: process.env.POSTGRES_USER || 'ai_gateway',
    password: process.env.POSTGRES_PASSWORD || '',
  },

  redis: {
    host: process.env.REDIS_HOST || 'redis',
    port: parseInt(process.env.REDIS_PORT || '6379', 10),
  },

  providers,

  // routing.capabilityDefaults: capability -> { providerName, model }, used by
  // router.js as the fast-path default before it falls through to generic
  // capability-tag matching / round-robin. See buildCapabilityRouting above.
  routing: {
    capabilityDefaults: capabilityRouting.routing,
  },
};

if (capabilityRouting.warnings.length > 0) {
  // eslint-disable-next-line no-console
  capabilityRouting.warnings.forEach((w) => console.warn(`[config] ${w}`));
}