import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { acquireFileLock } from '../src/shared/lock.js';

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test('keeper lock: heartbeat write failures mark the lock lost', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-lock-'));
  const lockPath = path.join(tmpDir, 'keeper.lock');
  const originalRenameSync = fs.renameSync;
  const logs: string[] = [];

  const lock = await acquireFileLock({
    lockPath,
    ttlMs: 200,
    heartbeatMs: 25,
    exitOnLost: false,
    log: (msg) => logs.push(msg),
  });

  try {
    fs.renameSync = ((oldPath: fs.PathLike, newPath: fs.PathLike) => {
      if (String(newPath) === lockPath) {
        const err = new Error('read-only filesystem') as NodeJS.ErrnoException;
        err.code = 'EROFS';
        throw err;
      }
      return originalRenameSync(oldPath, newPath);
    }) as typeof fs.renameSync;

    for (let i = 0; i < 20 && lock.isHeld(); i++) {
      await sleep(20);
    }

    assert.equal(lock.isHeld(), false);
    assert.match(lock.getLostReason() ?? '', /heartbeat_write_failed:EROFS/);
    assert.ok(logs.some((msg) => msg.includes('lock: LOST')));
  } finally {
    fs.renameSync = originalRenameSync;
    lock.release();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper lock: release does not unlink a corrupt lock file without ownership proof', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-lock-release-'));
  const lockPath = path.join(tmpDir, 'keeper.lock');
  const logs: string[] = [];

  const lock = await acquireFileLock({
    lockPath,
    ttlMs: 500,
    heartbeatMs: 0,
    exitOnLost: false,
    log: (msg) => logs.push(msg),
  });

  try {
    fs.writeFileSync(lockPath, '{not-json\n', 'utf8');
    lock.release();

    assert.equal(fs.existsSync(lockPath), true);
    assert.ok(logs.some((msg) => msg.includes('release skipped without ownership proof')));
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper lock: oversized existing lock file fails closed', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-lock-oversized-'));
  const lockPath = path.join(tmpDir, 'keeper.lock');

  fs.writeFileSync(lockPath, 'x'.repeat(16 * 1024 + 1), 'utf8');

  try {
    await assert.rejects(
      () =>
        acquireFileLock({
          lockPath,
          ttlMs: 500,
          heartbeatMs: 0,
          exitOnLost: false,
        }),
      /too large/i,
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper lock: malformed expiresAtMs falls back to mtime instead of breaking a fresh lock', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-lock-malformed-exp-'));
  const lockPath = path.join(tmpDir, 'keeper.lock');

  fs.writeFileSync(
    lockPath,
    JSON.stringify({
      ownerId: 'other-owner',
      pid: 123,
      createdAtMs: Date.now(),
      updatedAtMs: Date.now(),
      expiresAtMs: '1e3',
    }) + '\n',
    'utf8',
  );

  try {
    await assert.rejects(
      () =>
        acquireFileLock({
          lockPath,
          ttlMs: 1_000,
          heartbeatMs: 0,
          exitOnLost: false,
        }),
      /Lock already held:/,
    );
    assert.equal(fs.existsSync(lockPath), true);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
