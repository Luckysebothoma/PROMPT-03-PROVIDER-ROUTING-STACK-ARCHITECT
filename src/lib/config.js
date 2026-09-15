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

  providers: {
    groq: {
      apiKey: process.env.GROQ_API_KEY || '',
      // llama-3.1-8b-instant / llama-3.3-70b-versatile were retired by Groq
      // (shutdown Aug 16, 2026) — openai/gpt-oss-20b is the recommended
      // successor and stays fast + cheap for general chat.
      defaultModel: process.env.GROQ_DEFAULT_MODEL || 'openai/gpt-oss-20b',
      enabled: bool(process.env.GROQ_ENABLED, true),
      baseUrl: process.env.GROQ_BASE_URL || 'https://api.groq.com/openai/v1',
      implemented: true,
      models: GROQ_MODELS,
    },
    gemini: {
      apiKey: process.env.GEMINI_API_KEY || '',
      // gemini-1.5-flash is fully retired. gemini-3.6-flash is the current
      // GA workhorse (coding/agentic, good price/perf).
      defaultModel: process.env.GEMINI_DEFAULT_MODEL || 'gemini-3.6-flash',
      enabled: bool(process.env.GEMINI_ENABLED, true),
      baseUrl: process.env.GEMINI_BASE_URL || 'https://generativelanguage.googleapis.com/v1beta',
      implemented: true,
      models: GEMINI_MODELS,
    },
  },
};