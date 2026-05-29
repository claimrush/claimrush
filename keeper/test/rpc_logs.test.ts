import test from 'node:test';
import assert from 'node:assert/strict';

import { computeBackoffMs, jitterMs, parseRpcLogIndex } from '../src/shared/rpc_logs.js';

test('keeper rpc_logs: parseRpcLogIndex accepts canonical decimal and hex, rejects malformed strings', () => {
  assert.equal(parseRpcLogIndex(0), 0n);
  assert.equal(parseRpcLogIndex('7'), 7n);
  assert.equal(parseRpcLogIndex('0x2'), 2n);
  assert.equal(parseRpcLogIndex('0x10'), 16n);
  assert.equal(parseRpcLogIndex('1e3'), null);
  assert.equal(parseRpcLogIndex('7.0'), null);
  assert.equal(parseRpcLogIndex(-1), null);
});

test('keeper rpc_logs: malformed retry inputs fail closed to stable backoff defaults', () => {
  assert.equal(computeBackoffMs({ attempt: '2.5', baseMs: '250.5', maxMs: '1000.5' }), 1);
  assert.equal(jitterMs(1_000, '250.5'), 1_000);
});
