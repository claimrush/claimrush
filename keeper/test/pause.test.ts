import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import type { KeeperConfig } from '../src/shared/config.js';
import { getPauseInfo } from '../src/shared/pause.js';

function makeConfig(pauseFilePath: string): KeeperConfig {
  return {
    paused: false,
    pauseFilePath,
  } as KeeperConfig;
}

test('keeper pause: oversized pause file fails closed', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pause-'));
  const pauseFilePath = path.join(tmpDir, 'PAUSED');

  try {
    fs.writeFileSync(pauseFilePath, 'x'.repeat(64 * 1024 + 1), 'utf8');
    const pause = getPauseInfo(makeConfig(pauseFilePath));
    assert.equal(pause.paused, true);
    assert.match(pause.reason ?? '', /exceeds 65536 bytes/);
    assert.equal(pause.source, 'file');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper pause: directory pause path fails closed', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pause-'));
  const pauseFilePath = path.join(tmpDir, 'PAUSED');

  try {
    fs.mkdirSync(pauseFilePath);
    const pause = getPauseInfo(makeConfig(pauseFilePath));
    assert.equal(pause.paused, true);
    assert.match(pause.reason ?? '', /not a regular file/);
    assert.equal(pause.source, 'file');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
