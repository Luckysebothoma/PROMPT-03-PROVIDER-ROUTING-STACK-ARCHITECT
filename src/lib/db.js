const { Pool } = require('pg');
const config = require('./config');
const logger = require('./logger');

const pool = new Pool({
  host: config.postgres.host,
  port: config.postgres.port,
  database: config.postgres.database,
  user: config.postgres.user,
  password: config.postgres.password,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  logger.error({ operation: 'postgres_pool_error', error: err.message });
});

async function ping() {
  const res = await pool.query('SELECT 1 AS ok');
  return res.rows[0].ok === 1;
}

async function recordRequest({ requestId, provider, model, success, errorCode, durationMs }) {
  try {
    await pool.query(
      `INSERT INTO request_log (request_id, provider, model, success, error_code, duration_ms)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [requestId, provider || null, model || null, success, errorCode || null, durationMs || null]
    );
  } catch (err) {
    logger.warn({ operation: 'record_request_failed', error: err.message });
  }
}

module.exports = { pool, ping, recordRequest };
