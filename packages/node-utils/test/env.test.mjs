import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { loadEnvFile } from '../src/env.mjs';

function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-node-utils-env-'));
  try {
    return fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('loadEnvFile loads scalar values from a regular env file', () => {
  withTempDir((dir) => {
    const envPath = path.join(dir, 'sample.env');
    fs.writeFileSync(envPath, 'ALPHA=1\nBRAVO=\"two\"\n', 'utf8');

    delete process.env.ALPHA;
    delete process.env.BRAVO;

    const result = loadEnvFile('sample.env', { searchDirs: [dir] });
    assert.deepEqual(result, { loaded: true, count: 2 });
    assert.equal(process.env.ALPHA, '1');
    assert.equal(process.env.BRAVO, 'two');

    delete process.env.ALPHA;
    delete process.env.BRAVO;
  });
});

test('loadEnvFile rejects directory inputs', () => {
  withTempDir((dir) => {
    assert.throws(
      () => loadEnvFile(dir, { searchDirs: [dir] }),
      /not a regular file/,
    );
  });
});

test('loadEnvFile rejects oversized env files', () => {
  withTempDir((dir) => {
    const envPath = path.join(dir, 'oversized.env');
    fs.writeFileSync(envPath, `TOO_BIG=${'x'.repeat(300_000)}\n`, 'utf8');

    assert.throws(
      () => loadEnvFile(envPath, { searchDirs: [dir] }),
      /Env file too large/,
    );
  });
});
