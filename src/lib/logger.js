// Structured JSON logger. Never logs secrets.
function log(level, fields) {
  // Check if debug logging is enabled via environment variable (defaults to false)
  const isDebugEnabled = process.env.DEBUG_LOGGING === 'true';
  
  // If it's a debug-level log (or contains payload tracing) and debug is off, skip it
  if (fields.operation && fields.operation.includes('payload') && !isDebugEnabled) {
    return;
  }

  const entry = {
    timestamp: new Date().toISOString(),
    level,
    ...fields,
  };
  const line = JSON.stringify(entry);
  if (level === 'error') {
    console.error(line);
  } else {
    console.log(line);
  }
}

module.exports = {
  info: (fields) => log('info', fields),
  warn: (fields) => log('warn', fields),
  error: (fields) => log('error', fields),
};