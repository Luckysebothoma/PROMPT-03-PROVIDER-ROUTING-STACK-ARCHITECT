const { createClient } = require('redis');
const config = require('./config');
const logger = require('./logger');

const client = createClient({
  socket: {
    host: config.redis.host,
    port: config.redis.port,
    reconnectStrategy: (retries) => Math.min(retries * 100, 3000),
  },
});

client.on('error', (err) => {
  logger.warn({ operation: 'redis_error', error: err.message });
});

let connected = false;
const CONNECT_TIMEOUT_MS = 1500;

// node-redis's default reconnectStrategy retries the *initial* connect()
// indefinitely when Redis is unreachable. Without a bound here, any caller
// (readiness checks, routing) would hang forever instead of failing fast -
// e.g. GET /ready would never respond, and "auto" routing in
// src/lib/router.js would never reach its documented fallback path.
async function connect() {
  if (!connected) {
    await Promise.race([
      client.connect(),
      new Promise((_, reject) => {
        setTimeout(() => reject(new Error('Redis connect timed out')), CONNECT_TIMEOUT_MS);
      }),
    ]);
    connected = true;
  }
  return client;
}

async function ping() {
  await connect();
  const res = await client.ping();
  return res === 'PONG';
}

// Deterministic round-robin cursor for "auto" provider selection, stored in Redis
// so multiple replicas share routing state.
async function nextRoutingIndex(key, modulo) {
  await connect();
  const val = await client.incr(key);
  return modulo > 0 ? val % modulo : 0;
}

module.exports = { client, connect, ping, nextRoutingIndex };
