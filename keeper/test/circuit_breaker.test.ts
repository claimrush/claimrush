import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { loadCircuitBreakerState } from '../src/shared/circuit_breaker.js';
import { sendContractTx } from '../src/shared/tx.js';

function makeConfig(tmpDir: string, statePath: string) {
  return {
    pauseFilePath: path.join(tmpDir, 'PAUSED'),
    dryRun: false,
    allowTxWhilePending: true,
    txGasLimitMultiplierBps: 10_000,
    txMaxFeePerGasWei: null,
    txMaxPriorityFeePerGasWei: null,
    txMaxGasLimit: null,
    txMaxTotalFeeWei: null,
    txConfirmations: 1,
    txReceiptTimeoutMs: 1_000,
    circuitBreakerEnabled: true,
    circuitBreakerStatePath: statePath,
    circuitBreakerMaxFailures: 3,
    circuitBreakerCooldownMs: 60_000,
    deployment: 'test',
    alertWebhookUrl: '',
  } as any;
}

test('keeper circuit breaker: invalid JSON fails closed instead of resetting state', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-cb-'));
  const statePath = path.join(tmpDir, 'circuit_breaker.json');
  fs.writeFileSync(statePath, '{not-json', 'utf8');

  try {
    assert.throws(
      () => loadCircuitBreakerState(statePath),
      /circuit breaker state unreadable or invalid JSON/i,
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper tx: invalid circuit breaker state blocks tx submission before writeContract', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-cb-'));
  const statePath = path.join(tmpDir, 'circuit_breaker.json');
  fs.writeFileSync(
    statePath,
    JSON.stringify({ version: 1, consecutiveFailures: 'oops' }) + '\n',
    'utf8',
  );

  let writeCalls = 0;

  try {
    await assert.rejects(
      () =>
        sendContractTx({
          config: makeConfig(tmpDir, statePath),
          publicClient: {} as any,
          walletClient: {
            async writeContract() {
              writeCalls += 1;
              return `0x${'1'.repeat(64)}`;
            },
          } as any,
          account: { address: `0x${'1'.repeat(40)}` } as any,
          address: `0x${'2'.repeat(40)}` as any,
          abi: [],
          functionName: 'poke',
          args: [],
        }),
      /circuit breaker/i,
    );
    assert.equal(writeCalls, 0);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper circuit breaker: exponent-style consecutiveFailures is rejected', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-cb-'));
  const statePath = path.join(tmpDir, 'circuit_breaker.json');
  fs.writeFileSync(
    statePath,
    JSON.stringify({ version: 1, consecutiveFailures: '1e2' }) + '\n',
    'utf8',
  );

  try {
    assert.throws(
      () => loadCircuitBreakerState(statePath),
      /consecutiveFailures must be a non-negative integer/i,
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper tx: tripped breaker state still blocks sends when pause-file write fails', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-cb-'));
  const statePath = path.join(tmpDir, 'circuit_breaker.json');
  const config = {
    ...makeConfig(tmpDir, statePath),
    circuitBreakerMaxFailures: 1,
  } as any;

  const originalOpenSync = fs.openSync;
  let writeCalls = 0;

  fs.openSync = ((filePath: fs.PathLike, flags: string | number, mode?: fs.Mode) => {
    const asString = String(filePath);
    if (asString.startsWith(`${config.pauseFilePath}.tmp.`)) {
      const err = new Error('pause disk full') as NodeJS.ErrnoException;
      err.code = 'ENOSPC';
      throw err;
    }
    return originalOpenSync(filePath, flags as any, mode as any);
  }) as typeof fs.openSync;

  try {
    await assert.rejects(
      () =>
        sendContractTx({
          config,
          publicClient: {
            async estimateContractGas() {
              return 21_000n;
            },
          } as any,
          walletClient: {
            async writeContract() {
              writeCalls += 1;
              throw new Error('rpc down');
            },
          } as any,
          account: { address: `0x${'1'.repeat(40)}` } as any,
          address: `0x${'2'.repeat(40)}` as any,
          abi: [],
          functionName: 'poke',
          args: [],
        }),
      /rpc down/,
    );

    const breakerState = loadCircuitBreakerState(statePath);
    assert.equal(breakerState.consecutiveFailures, 1);
    assert.ok(breakerState.trippedAtUtc);
    assert.ok(breakerState.pausedUntilUtc);

    const skipped = await sendContractTx({
      config,
      publicClient: {
        async estimateContractGas() {
          return 21_000n;
        },
      } as any,
      walletClient: {
        async writeContract() {
          writeCalls += 1;
          return `0x${'4'.repeat(64)}`;
        },
      } as any,
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
    });

    assert.deepEqual(skipped, {
      ok: false,
      skipped: true,
      reason: `paused (state): circuit breaker tripped (until ${breakerState.pausedUntilUtc})`,
      code: 'paused',
    });
    assert.equal(writeCalls, 1);
  } finally {
    fs.openSync = originalOpenSync;
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('keeper tx: confirmed tx success is preserved when breaker-state persistence fails after receipt', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-cb-'));
  const statePath = path.join(tmpDir, 'circuit_breaker.json');
  fs.writeFileSync(
    statePath,
    JSON.stringify({
      version: 1,
      consecutiveFailures: 0,
      lastFailureAtUtc: null,
      lastSuccessAtUtc: null,
      trippedAtUtc: null,
      pausedUntilUtc: null,
      lastError: null,
    }) + '\n',
    'utf8',
  );

  const originalOpenSync = fs.openSync;
  const logs: string[] = [];
  let writeCalls = 0;

  fs.openSync = ((filePath: fs.PathLike, flags: string | number, mode?: fs.Mode) => {
    const asString = String(filePath);
    if (asString.startsWith(`${statePath}.tmp.`)) {
      const err = new Error('disk full') as NodeJS.ErrnoException;
      err.code = 'ENOSPC';
      throw err;
    }
    return originalOpenSync(filePath, flags as any, mode as any);
  }) as typeof fs.openSync;

  try {
    const result = await sendContractTx({
      config: makeConfig(tmpDir, statePath),
      publicClient: {
        async estimateContractGas() {
          return 21_000n;
        },
        async getTransactionReceipt() {
          return { status: 'success' };
        },
      } as any,
      walletClient: {
        async writeContract() {
          writeCalls += 1;
          return `0x${'3'.repeat(64)}`;
        },
      } as any,
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
      log: (msg: string) => logs.push(msg),
    });

    assert.equal(result.ok, true);
    assert.equal(writeCalls, 1);
    assert.ok(logs.some((msg) => msg.includes('success-state persistence failed')));
    assert.equal(loadCircuitBreakerState(statePath).version, 1);
  } finally {
    fs.openSync = originalOpenSync;
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
