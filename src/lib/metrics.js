const client = require('prom-client');

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const chatRequestsTotal = new client.Counter({
  name: 'chat_requests_total',
  help: 'Total number of /v1/chat requests received',
  registers: [register],
});

const chatRequestsSuccessTotal = new client.Counter({
  name: 'chat_requests_success_total',
  help: 'Total number of successful /v1/chat requests',
  registers: [register],
});

const chatRequestsFailedTotal = new client.Counter({
  name: 'chat_requests_failed_total',
  help: 'Total number of failed /v1/chat requests',
  registers: [register],
});

const providerRequestsTotal = new client.Counter({
  name: 'provider_requests_total',
  help: 'Total number of requests routed to a provider',
  labelNames: ['provider', 'model'],
  registers: [register],
});

const providerRequestsSuccessTotal = new client.Counter({
  name: 'provider_requests_success_total',
  help: 'Total number of successful provider executions',
  labelNames: ['provider', 'model'],
  registers: [register],
});

const providerRequestsFailedTotal = new client.Counter({
  name: 'provider_requests_failed_total',
  help: 'Total number of failed provider executions',
  labelNames: ['provider', 'model', 'error_code'],
  registers: [register],
});

const providerRequestDurationSeconds = new client.Histogram({
  name: 'provider_request_duration_seconds',
  help: 'Duration of provider execution requests in seconds',
  labelNames: ['provider', 'model'],
  buckets: [0.1, 0.3, 0.5, 1, 2, 5, 10, 20],
  registers: [register],
});

module.exports = {
  register,
  chatRequestsTotal,
  chatRequestsSuccessTotal,
  chatRequestsFailedTotal,
  providerRequestsTotal,
  providerRequestsSuccessTotal,
  providerRequestsFailedTotal,
  providerRequestDurationSeconds,
};
