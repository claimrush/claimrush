import test from 'node:test';
import assert from 'node:assert/strict';

import { parseBool, parseIntStrict } from '../src/env.mjs';

test('parseBool accepts common truthy spellings', () => {
  for (const v of ['1', 'true', 'TRUE', 'yes', 'Y', 'on', 'On']) {
    assert.equal(parseBool(v), true, `expected truthy for ${JSON.stringify(v)}`);
  }
});

test('parseBool accepts common falsy spellings', () => {
  for (const v of ['0', 'false', 'FALSE', 'no', 'N', 'off', 'Off']) {
    assert.equal(parseBool(v), false, `expected falsy for ${JSON.stringify(v)}`);
  }
});

test('parseBool returns default for null/undefined/empty/unknown', () => {
  assert.equal(parseBool(null), false);
  assert.equal(parseBool(undefined), false);
  assert.equal(parseBool(''), false);
  assert.equal(parseBool('maybe'), false);
  assert.equal(parseBool('maybe', { defaultValue: true }), true);
  assert.equal(parseBool(null, { defaultValue: true }), true);
});

test('parseIntStrict accepts canonical integer strings', () => {
  assert.equal(parseIntStrict('0'), 0);
  assert.equal(parseIntStrict('42'), 42);
  assert.equal(parseIntStrict('-7'), -7);
  assert.equal(parseIntStrict('+9'), 9);
  assert.equal(parseIntStrict('  100  '), 100);
});

test('parseIntStrict rejects non-canonical forms', () => {
  assert.equal(parseIntStrict('1.5'), null);
  assert.equal(parseIntStrict('10ms'), null);
  assert.equal(parseIntStrict('0x10'), null);
  assert.equal(parseIntStrict('1e3'), null);
  assert.equal(parseIntStrict(''), null);
  assert.equal(parseIntStrict(null), null);
  assert.equal(parseIntStrict(undefined), null);
  assert.equal(parseIntStrict('abc'), null);
});

test('parseIntStrict honors custom defaults', () => {
  assert.equal(parseIntStrict(undefined, { defaultValue: 123 }), 123);
  assert.equal(parseIntStrict('bogus', { defaultValue: -1 }), -1);
});
