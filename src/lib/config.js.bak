require('dotenv').config();

function bool(v, def = false) {
  if (v === undefined || v === null || v === '') return def;
  return String(v).toLowerCase() === 'true';
}

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
      defaultModel: process.env.GROQ_DEFAULT_MODEL || 'llama-3.1-8b-instant',
      enabled: bool(process.env.GROQ_ENABLED, true),
      baseUrl: process.env.GROQ_BASE_URL || 'https://api.groq.com/openai/v1',
      implemented: true,
    },
    gemini: {
      apiKey: process.env.GEMINI_API_KEY || '',
      defaultModel: process.env.GEMINI_DEFAULT_MODEL || 'gemini-1.5-flash',
      enabled: bool(process.env.GEMINI_ENABLED, true),
      implemented: false,
    },
  },
};
