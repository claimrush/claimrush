import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { sendContractTx } from '../src/shared/tx.js';

function makeConfig(tmpDir: string) {
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
    circuitBreakerStatePath: path.join(tmpDir, 'cb.json'),
    circuitBreakerMaxFailures: 3,
    circuitBreakerCooldownMs: 60_000,
    deployment: 'test',
    alertWebhookUrl: '',
  } as any;
}

function makePublicClient(opts: {
  balanceBefore: bigint;
  balanceAfter: bigint;
  gasUsed: bigint;
  effectiveGasPrice: bigint;
  /// OP-stack L1 data-posting fee. Absent on Ethereum L1 receipts; mock omits
  /// the field when undefined to match real receipt shape.
  l1Fee?: bigint;
}) {
  let nextBalance = opts.balanceBefore;
  const baseReceipt = {
    status: 'success' as const,
    gasUsed: opts.gasUsed,
    effectiveGasPrice: opts.effectiveGasPrice,
  };
  const receipt = opts.l1Fee !== undefined ? { ...baseReceipt, l1Fee: opts.l1Fee } : baseReceipt;
  return {
    async getBalance() {
      const v = nextBalance;
      nextBalance = opts.balanceAfter;
      return v;
    },
    async estimateContractGas() {
      return 100_000n;
    },
    async getBlock() {
      return { timestamp: 0n, baseFeePerGas: 0n };
    },
    async getTransactionReceipt() {
      return receipt;
    },
    async waitForTransactionReceipt() {
      return receipt;
    },
    async getTransactionCount() {
      return 0;
    },
  } as any;
}

function makeWalletClient(hash: `0x${string}`) {
  return {
    async writeContract() {
      return hash;
    },
    async getTransactionCount() {
      return 0;
    },
    async request({ method }: { method: string }) {
      if (method === 'eth_getTransactionCount') return '0x0';
      return null;
    },
  } as any;
}

test('payout-bound runtime guard: clean tx returns ok with payoutBoundViolation=null', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pb-'));
  try {
    const gasUsed = 100_000n;
    const effectiveGasPrice = 1_000_000_000n; // 1 gwei
    const gasSpent = gasUsed * effectiveGasPrice;

    const balanceBefore = 10n ** 18n;
    const balanceAfter = balanceBefore - gasSpent;

    const result = await sendContractTx({
      config: makeConfig(tmpDir),
      publicClient: makePublicClient({ balanceBefore, balanceAfter, gasUsed, effectiveGasPrice }),
      walletClient: makeWalletClient(`0x${'a'.repeat(64)}` as `0x${string}`),
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
    });

    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(result.payoutBoundViolation, null);
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('payout-bound runtime guard: positive EOA delta sets payoutBoundViolation', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pb-'));
  try {
    const gasUsed = 100_000n;
    const effectiveGasPrice = 1_000_000_000n;
    const gasSpent = gasUsed * effectiveGasPrice;

    // Tampered: contract paid msg.sender 1 wei despite gas being spent.
    const balanceBefore = 10n ** 18n;
    const balanceAfter = balanceBefore - gasSpent + 1n;

    const result = await sendContractTx({
      config: makeConfig(tmpDir),
      publicClient: makePublicClient({ balanceBefore, balanceAfter, gasUsed, effectiveGasPrice }),
      walletClient: makeWalletClient(`0x${'b'.repeat(64)}` as `0x${string}`),
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
    });

    assert.equal(result.ok, true);
    if (result.ok) {
      assert.notEqual(result.payoutBoundViolation, null);
      assert.match(
        result.payoutBoundViolation!.reason,
        /(received|exceeds|outflow|less than (gasSpent|totalCost))/,
      );
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('payout-bound runtime guard: OP-stack receipt with l1Fee passes audit (no false positive)', async () => {
  // Regression for the 2026-05-07 Sepolia rehearsal: Base receipts include an
  // `l1Fee` field for the L1 data-posting cost, deducted from the EOA at
  // execution time alongside L2 gas. Pre-fix the audit only counted L2 gas
  // and produced a false-positive `unauthorized withdrawal` of exactly
  // `l1Fee` wei on every keeper tx. Mocked here as the exact wire values
  // observed on tx 0xfe5f88775586e66f96e5fd050d56683ab8599f2cad4b0b1acbe4fa81ba1d4c2f.
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pb-'));
  try {
    const gasUsed = 198_018n;
    const effectiveGasPrice = 1_005_000_000n; // 1.005 gwei
    const l1Fee = 95n;
    const totalCost = gasUsed * effectiveGasPrice + l1Fee;

    const balanceBefore = 28_622_034_062_649_571_922n;
    const balanceAfter = balanceBefore - totalCost;

    const result = await sendContractTx({
      config: makeConfig(tmpDir),
      publicClient: makePublicClient({
        balanceBefore,
        balanceAfter,
        gasUsed,
        effectiveGasPrice,
        l1Fee,
      }),
      walletClient: makeWalletClient(`0x${'d'.repeat(64)}` as `0x${string}`),
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
    });

    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(
        result.payoutBoundViolation,
        null,
        'OP-stack receipt with l1Fee summed into totalCost must not trip the audit',
      );
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('payout-bound runtime guard: OP-stack tx with l1Fee but otherwise tampered still fails', async () => {
  // Belt-and-suspenders: confirm that summing l1Fee into totalCost does not
  // mask actual EOA-side anomalies. Here the EOA loses gas + l1Fee + 7 wei,
  // which should still trip the audit with a 7-wei excess outflow.
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pb-'));
  try {
    const gasUsed = 198_018n;
    const effectiveGasPrice = 1_005_000_000n;
    const l1Fee = 95n;
    const totalCost = gasUsed * effectiveGasPrice + l1Fee;

    const balanceBefore = 28_622_034_062_649_571_922n;
    const balanceAfter = balanceBefore - totalCost - 7n; // 7 wei excess

    const result = await sendContractTx({
      config: makeConfig(tmpDir),
      publicClient: makePublicClient({
        balanceBefore,
        balanceAfter,
        gasUsed,
        effectiveGasPrice,
        l1Fee,
      }),
      walletClient: makeWalletClient(`0x${'e'.repeat(64)}` as `0x${string}`),
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
    });

    assert.equal(result.ok, true);
    if (result.ok) {
      assert.notEqual(result.payoutBoundViolation, null);
      assert.match(result.payoutBoundViolation!.reason, /exceeds totalCost .* by 7 wei/);
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('payout-bound runtime guard: pre-tx balance read failure does not block submission', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pb-'));
  try {
    const publicClient = {
      async getBalance() {
        throw new Error('rpc down');
      },
      async estimateContractGas() {
        return 100_000n;
      },
      async getBlock() {
        return { timestamp: 0n, baseFeePerGas: 0n };
      },
      async getTransactionReceipt() {
        return { status: 'success', gasUsed: 100_000n, effectiveGasPrice: 1_000_000_000n };
      },
      async waitForTransactionReceipt() {
        return { status: 'success', gasUsed: 100_000n, effectiveGasPrice: 1_000_000_000n };
      },
      async getTransactionCount() {
        return 0;
      },
    } as any;

    const result = await sendContractTx({
      config: makeConfig(tmpDir),
      publicClient,
      walletClient: makeWalletClient(`0x${'c'.repeat(64)}` as `0x${string}`),
      account: { address: `0x${'1'.repeat(40)}` } as any,
      address: `0x${'2'.repeat(40)}` as any,
      abi: [],
      functionName: 'poke',
      args: [],
    });

    // Audit disabled: tx still confirms ok with payoutBoundViolation=null.
    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(result.payoutBoundViolation, null);
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
