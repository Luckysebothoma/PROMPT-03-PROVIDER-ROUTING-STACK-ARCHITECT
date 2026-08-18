const express = require('express');
const { v4: uuidv4 } = require('uuid');
const config = require('./lib/config');
const logger = require('./lib/logger');
const metaRoutes = require('./routes/meta');
const chatRoutes = require('./routes/chat');

const app = express();
app.use(express.json({ limit: '1mb' }));

app.use((req, res, next) => {
  if (!req.headers['x-request-id']) {
    req.headers['x-request-id'] = uuidv4();
  }
  next();
});

app.use('/', metaRoutes);
app.use('/', chatRoutes);

app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: { code: 'NOT_FOUND', message: `No such route: ${req.method} ${req.path}` },
  });
});

app.use((err, req, res, next) => {
  logger.error({ operation: 'unhandled_error', error: err.message });
  res.status(500).json({
    success: false,
    error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' },
  });
});

app.listen(config.port, '0.0.0.0', () => {
  logger.info({
    operation: 'startup',
    message: `${config.serviceName} listening on 0.0.0.0:${config.port}`,
  });
});
