// PATCH_MARKER_META_ROUTE_V2
const express = require('express');
const config = require('../lib/config');
const db = require('../lib/db');
const redisClient = require('../lib/redisClient');
const registry = require('../providers/registry');
const metrics = require('../lib/metrics');

const router = express.Router();

router.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    service: config.serviceName,
    timestamp: new Date().toISOString(),
  });
});

router.get('/ready', async (req, res) => {
  const checks = { postgres: false, redis: false };
  try {
    checks.postgres = await db.ping();
  } catch (_) { checks.postgres = false; }
  try {
    checks.redis = await redisClient.ping();
  } catch (_) { checks.redis = false; }

  const ready = checks.postgres && checks.redis;
  res.status(ready ? 200 : 503).json({
    status: ready ? 'ready' : 'not_ready',
    checks,
  });
});

router.get('/dependencies', async (req, res) => {
  const deps = {
    postgres: { host: config.postgres.host, port: config.postgres.port, reachable: false },
    redis: { host: config.redis.host, port: config.redis.port, reachable: false },
  };
  try { deps.postgres.reachable = await db.ping(); } catch (_) { /* noop */ }
  try { deps.redis.reachable = await redisClient.ping(); } catch (_) { /* noop */ }
  res.json({ dependencies: deps });
});

router.get('/providers', (req, res) => {
  res.json({ providers: registry.publicProviderList() });
});

// GET /capabilities - which capability/intent tags exist right now, which
// (provider, model) workers advertise each one, and whether that worker is
// currently available (enabled+configured). Lets an upstream classify layer
// (or a human) discover valid `capability`/`intent` values without reading
// source.
router.get('/capabilities', (req, res) => {
  const workers = registry.listWorkers();
  const byCapability = {};
  for (const w of workers) {
    for (const cap of w.capabilities) {
      if (!byCapability[cap]) byCapability[cap] = [];
      byCapability[cap].push({ provider: w.provider, model: w.model, available: w.available });
    }
  }
  res.json({
    capabilities: registry.allCapabilities(),
    workers_by_capability: byCapability,
  });
});

router.get('/help', (req, res) => {
  res.json({
    service: config.serviceName,
    description: 'Day 3 - Provider Routing & Execution Stack',
    endpoints: {
      'POST /v1/chat/groq': 'Execute a single-message chat request using Groq',
      'POST /v1/chat/gemini': 'Execute a single-message chat request using Gemini',
      'GET /health': 'Liveness check',
      'GET /ready': 'Readiness check (postgres + redis)',
      'GET /dependencies': 'Dependency connectivity status',
      'GET /providers': 'Provider registry state, including each provider\'s model catalog and capability tags (no secrets)',
      'GET /capabilities': 'Known capability/intent tags and which (provider, model) workers can serve each one',
      'GET /help': 'This message',
      'GET /metrics': 'Prometheus metrics',
      'POST /v1/chat': 'Route and execute a single-message chat request against a provider. Accepts optional "capability" (alias "intent") to route by need instead of by provider name',
      'POST /v1/execute': 'Provider-neutral execution contract for upstream orchestration (e.g. Stack 5): resolves provider/model (directly, or via "capability"/"intent"), executes structured messages[], returns a normalized result',
    },
    routing_strategy: [
      '1. Explicit provider',
      '2. Explicit model (used once a provider is resolved)',
      '3. capability/intent hint -> round-robin across workers tagged with that capability (falls through to step 4 if none match)',
      '4. Automatic selection (auto / omitted provider) -> round-robin across all implemented+enabled+configured providers',
      '5. First healthy implemented provider (fallback if Redis is unavailable)',
    ],
  });
});

router.get('/metrics', async (req, res) => {
  res.set('Content-Type', metrics.register.contentType);
  res.end(await metrics.register.metrics());
});

module.exports = router;
