import test from 'node:test';
import assert from 'node:assert/strict';

import { makeNodeLogger, serializeError } from '../src/logger.mjs';

function captureLine(fn) {
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  const lines = [];
  const capture = (s) => lines.push(String(s));
  console.log = capture;
  console.warn = capture;
  console.error = capture;
  try {
    fn();
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }
  return lines;
}

test('makeNodeLogger emits a JSON line with base + call fields', () => {
  const log = makeNodeLogger({ component: 'test-service', nodeId: 'abc' });
  const [line] = captureLine(() => log.info('hello', { requestId: 'req-1' }));
  const obj = JSON.parse(line);
  assert.equal(obj.level, 'info');
  assert.equal(obj.msg, 'hello');
  assert.equal(obj.component, 'test-service');
  assert.equal(obj.nodeId, 'abc');
  assert.equal(obj.requestId, 'req-1');
  assert.ok(typeof obj.ts === 'string' && obj.ts.length > 0);
});

test('makeNodeLogger redacts sensitive field keys', () => {
  const log = makeNodeLogger();
  const [line] = captureLine(() =>
    log.info('probe', {
      authorization: 'Bearer xxxx.yyyy.zzzz',
      password: 'hunter2',
      privateKey: '0xdeadbeef',
      mnemonic: 'redact-me-mnemonic-placeholder',
      apiKey: 'sk-live-12345678',
      tokenId: '42',
    }),
  );
  const obj = JSON.parse(line);
  assert.equal(obj.authorization, '[redacted]');
  assert.equal(obj.password, '[redacted]');
  assert.equal(obj.privateKey, '[redacted]');
  assert.equal(obj.mnemonic, '[redacted]');
  assert.equal(obj.apiKey, '[redacted]');
  assert.equal(obj.tokenId, '42');
});

test('makeNodeLogger redacts secrets/PII inside string values', () => {
  const log = makeNodeLogger();
  const [line] = captureLine(() =>
    log.warn('failed for user@example.com vitalik.eth', {
      url: 'https://mainnet.infura.io/v3/abc123def456',
      header: 'Bearer abcdefghij',
      addr: '0x1234567890abcdef1234567890abcdef12345678',
    }),
  );
  const obj = JSON.parse(line);
  assert.ok(!obj.msg.includes('user@example.com'), 'email should be redacted');
  assert.ok(!obj.msg.includes('vitalik.eth'), 'ENS should be redacted');
  assert.ok(obj.url.includes('[redacted]'), 'provider path token should be redacted');
  assert.ok(obj.header.includes('Bearer [redacted]'));
  assert.equal(obj.addr, '0x[addr]');
});

test('makeNodeLogger preserves tx hashes in structured fields', () => {
  const log = makeNodeLogger();
  const hash = '0x' + 'a'.repeat(64);
  const [line] = captureLine(() => log.info('sent', { txHash: hash }));
  const obj = JSON.parse(line);
  assert.equal(obj.txHash, hash);
});

test('child loggers merge base fields', () => {
  const root = makeNodeLogger({ component: 'keeper' });
  const child = root.child({ chainId: 8453 });
  const [line] = captureLine(() => child('tick', { n: 1 }));
  const obj = JSON.parse(line);
  assert.equal(obj.component, 'keeper');
  assert.equal(obj.chainId, 8453);
  assert.equal(obj.n, 1);
});

test('serializeError returns name/message/stack with redaction', () => {
  const e = new Error('failed at https://mainnet.infura.io/v3/secret-abc-def');
  e.name = 'RpcError';
  const out = serializeError(e);
  assert.equal(out.name, 'RpcError');
  assert.ok(out.message.includes('[redacted]'));
  assert.ok(typeof out.stack === 'string' && out.stack.length > 0);
});

test('serializeError bounds stack to ~12 lines', () => {
  const e = new Error('boom');
  e.stack = 'Error: boom\n' + Array.from({ length: 50 }, (_, i) => `    at frame${i} (f:${i})`).join('\n');
  const out = serializeError(e);
  const lineCount = out.stack.split('\n').length;
  assert.ok(lineCount <= 13, `expected <=13 stack lines, got ${lineCount}`);
});

test('serializeError handles non-Error inputs', () => {
  assert.deepEqual(serializeError('plain string'), { message: 'plain string' });
  assert.deepEqual(serializeError(null), { message: 'UNKNOWN_ERROR' });
  assert.deepEqual(serializeError(undefined), { message: 'UNKNOWN_ERROR' });
});

test('logger caps object depth and array length', () => {
  const log = makeNodeLogger();
  const deep = { a: { b: { c: { d: { e: { f: { g: 'leaf' } } } } } } };
  const [line] = captureLine(() => log.info('deep', { deep }));
  const obj = JSON.parse(line);
  assert.ok(
    JSON.stringify(obj).includes('[object]'),
    'deeply nested objects should be truncated',
  );
});
