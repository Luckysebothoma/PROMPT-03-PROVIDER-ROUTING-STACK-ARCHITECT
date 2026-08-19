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

router.get('/help', (req, res) => {
  res.json({
    service: config.serviceName,
    description: 'Day 3 - Provider Routing & Execution Stack',
    endpoints: {
      'GET /health': 'Liveness check',
      'GET /ready': 'Readiness check (postgres + redis)',
      'GET /dependencies': 'Dependency connectivity status',
      'GET /providers': 'Provider registry state (no secrets)',
      'GET /help': 'This message',
      'GET /metrics': 'Prometheus metrics',
      'POST /v1/chat': 'Route and execute a chat request against a provider',
    },
    routing_strategy: [
      '1. Explicit provider',
      '2. Explicit model',
      '3. Automatic selection (auto)',
      '4. First healthy implemented provider',
    ],
  });
});

router.get('/metrics', async (req, res) => {
  res.set('Content-Type', metrics.register.contentType);
  res.end(await metrics.register.metrics());
});

module.exports = router;
