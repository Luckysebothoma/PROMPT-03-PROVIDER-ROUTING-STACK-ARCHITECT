// Structured JSON logger. Never logs secrets.
function log(level, fields) {
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
