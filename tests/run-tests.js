#!/usr/bin/env node
// PATCH_MARKER_RUN_TESTS_V1
// Stack 3 (Day 3) test suite: infrastructure checks + real /v1/chat and
// /v1/execute execution tests against a running instance.
//
// Distinguishes:
//   INFRASTRUCTURE PASS / FAIL
//   PROVIDER CONFIGURATION MISSING (GROQ_API_KEY unset -> not a code failure)
//   PROVIDER EXECUTION FAILED (a real execution/code failure)
'use strict';

const http = require('http');
const https = require('https');
const { URL } = require('url');

const BASE_URL = process.env.DAY3_URL || 'http://localhost:4405';

let pass = 0;
let fail = 0;
let skip = 0;

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE_URL);
    const lib = url.protocol === 'https:' ? https : http;
    const payload = body ? JSON.stringify(body) : null;
    const req = lib.request(url, {
      method,
      headers: payload
        ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
        : {},
      timeout: 15000,
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch (_) { /* not JSON, e.g. /metrics */ }
        resolve({ status: res.statusCode, body: json, raw: data });
      });
    });
    req.on('timeout', () => req.destroy(new Error('request timed out')));
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function ok(label, cond, detail) {
  if (cond) {
    pass += 1;
    console.log(`[PASS] ${label}`);
  } else {
    fail += 1;
    console.log(`[FAIL] ${label}${detail ? ` - ${detail}` : ''}`);
  }
}

function info(label) {
  skip += 1;
  console.log(`[SKIP] ${label}`);
}

async function main() {
  console.log(`Stack 3 test suite against ${BASE_URL}`);

  let reachable = true;
  try {
    const health = await request('GET', '/health');
    ok('GET /health -> 200', health.status === 200, `got ${health.status}`);
  } catch (err) {
    reachable = false;
    fail += 1;
    console.log(`[FAIL] Could not reach ${BASE_URL}: ${err.message}`);
  }

  if (!reachable) {
    console.log('\nINFRASTRUCTURE: FAIL (service unreachable, remaining tests skipped)');
    process.exitCode = 1;
    return;
  }

  const ready = await request('GET', '/ready');
  ok('GET /ready -> 200/503 with checks', [200, 503].includes(ready.status) && ready.body && 'checks' in ready.body);

  const deps = await request('GET', '/dependencies');
  ok('GET /dependencies -> 200', deps.status === 200);

  const providers = await request('GET', '/providers');
  ok('GET /providers -> 200', providers.status === 200 && Array.isArray(providers.body && providers.body.providers));

  const help = await request('GET', '/help');
  const endpointKeys = (help.body && help.body.endpoints) ? Object.keys(help.body.endpoints) : [];
  ok('GET /help advertises POST /v1/execute', help.status === 200 && endpointKeys.some((k) => k.includes('/v1/execute')));
  ok('GET /help still advertises POST /v1/chat', endpointKeys.some((k) => k.includes('/v1/chat')));

  const metricsRes = await request('GET', '/metrics');
  ok('GET /metrics -> 200 Prometheus exposition', metricsRes.status === 200 && /^# HELP/m.test(metricsRes.raw));

  console.log('\nINFRASTRUCTURE: PASS');

  const providerList = (providers.body && providers.body.providers) || [];
  const groq = providerList.find((p) => p.name === 'groq');
  const gemini = providerList.find((p) => p.name === 'gemini');
  ok('groq present in /providers', Boolean(groq));
  ok('gemini present in /providers with implemented=false', Boolean(gemini) && gemini.implemented === false);

  const groqConfigured = Boolean(groq && groq.configured);
  const model = groq && groq.defaultModel;

  if (!groqConfigured) {
    console.log('\nPROVIDER CONFIGURATION MISSING: GROQ_API_KEY is not set - skipping real execution tests.');
    info('POST /v1/chat real Groq execution');
    info('POST /v1/execute real Groq execution');
  } else {
    const chatRes = await request('POST', '/v1/chat', { message: 'Say OK', provider: 'groq' });
    ok('POST /v1/chat real Groq execution', chatRes.status === 200 && chatRes.body && chatRes.body.success === true, `status=${chatRes.status} body=${chatRes.raw.slice(0, 200)}`);
    ok('POST /v1/chat response has request_id', Boolean(chatRes.body && chatRes.body.request_id));

    const execRes = await request('POST', '/v1/execute', {
      provider: 'groq',
      model,
      messages: [{ role: 'user', content: 'Reply with exactly: STACK3_EXECUTION_OK' }],
    });
    ok(
      'POST /v1/execute -> 200 with provider/model/response/request_id',
      execRes.status === 200
        && execRes.body && execRes.body.success === true
        && execRes.body.provider === 'groq'
        && typeof execRes.body.response === 'string'
        && Boolean(execRes.body.request_id),
      `status=${execRes.status} body=${execRes.raw.slice(0, 200)}`
    );

    const multi = await request('POST', '/v1/execute', {
      provider: 'groq',
      model,
      messages: [
        { role: 'system', content: 'You are terse.' },
        { role: 'user', content: 'Reply with exactly: STACK3_EXECUTION_OK' },
      ],
    });
    ok('POST /v1/execute accepts multi-message conversations', multi.status === 200 && multi.body && multi.body.success === true);

    const auto = await request('POST', '/v1/execute', { messages: [{ role: 'user', content: 'ping' }] });
    ok('POST /v1/execute automatic routing selects an executable provider', auto.status === 200 && auto.body && auto.body.success === true, `status=${auto.status}`);
  }

  const geminiRes = await request('POST', '/v1/execute', { provider: 'gemini', messages: [{ role: 'user', content: 'hi' }] });
  ok('POST /v1/execute provider=gemini is rejected, not faked', geminiRes.status >= 400 && geminiRes.body && geminiRes.body.success === false);

  const unknownRes = await request('POST', '/v1/execute', { provider: 'not-a-real-provider', messages: [{ role: 'user', content: 'hi' }] });
  ok('POST /v1/execute unknown provider -> PROVIDER_NOT_FOUND', unknownRes.status >= 400 && unknownRes.body && unknownRes.body.error && unknownRes.body.error.code === 'PROVIDER_NOT_FOUND');

  const invalidRes = await request('POST', '/v1/execute', { provider: 'groq' });
  ok('POST /v1/execute missing messages[] -> 400 INVALID_REQUEST', invalidRes.status === 400 && invalidRes.body && invalidRes.body.error && invalidRes.body.error.code === 'INVALID_REQUEST');

  const invalidRes2 = await request('POST', '/v1/execute', { provider: 'groq', messages: 'hi' });
  ok('POST /v1/execute messages not an array -> 400 INVALID_REQUEST', invalidRes2.status === 400 && invalidRes2.body && invalidRes2.body.error && invalidRes2.body.error.code === 'INVALID_REQUEST');

  const legacyShape = await request('POST', '/v1/execute', { provider: 'groq', message: 'hi' });
  ok('POST /v1/execute rejects legacy {message} shape (not an alias of /v1/chat)', legacyShape.status === 400);

  const chatRejects = await request('POST', '/v1/chat', { messages: [{ role: 'user', content: 'hi' }] });
  ok('POST /v1/chat rejects messages[] (single "message" string contract preserved)', chatRejects.status === 400);

  console.log(`\n${pass} passed, ${fail} failed, ${skip} skipped`);
  if (fail > 0) process.exitCode = 1;
}

main().catch((err) => {
  console.error('Test suite crashed:', err);
  process.exitCode = 1;
});
