/**
 * Adversarial keeper sim — payout-bound circuit-breaker against a Base mainnet fork.
 *
 * Purpose: prove that `assertKeeperEoaPayoutBound` (wired into `sendContractTx`)
 * trips the circuit breaker end-to-end against a real EVM environment when a
 * faulty contract returns ETH to the keeper EOA on a state-changing call. The
 * standard `payout_bound_runtime.test.ts` exercises the wiring with mocks; this
 * sim runs the production code path against a forked-mainnet anvil instance
 * and a hand-bytecoded `AdversarialPayer` contract that always pays 1 wei back
 * to `msg.sender`.
 *
 * The test SKIPs when `BASE_MAINNET_RPC_URL` is not set, so it does not run as
 * part of the default `npm test` lane on CI without the explicit RPC env.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';

import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';

import { sendContractTx } from '../src/shared/tx.js';
import { loadCircuitBreakerState } from '../src/shared/circuit_breaker.js';

const BASE_RPC = process.env.BASE_MAINNET_RPC_URL ?? '';
const FORK_BLOCK = process.env.BASE_MAINNET_FORK_BLOCK ?? '';

// Hand-bytecoded `AdversarialPayer`:
//   constructor (12 bytes): CODECOPY runtime to mem[0..0x02]; RETURN
//   runtime     (2 bytes):  CALLER; SELFDESTRUCT — transfers the contract's
//                            entire balance to the caller on every invocation.
//                            Post-EIP-6780 SELFDESTRUCT in a non-creation tx is
//                            a balance-transfer-only opcode, which is exactly
//                            the behaviour we want here: any state-changing
//                            call to this contract drains its ETH balance to
//                            `msg.sender`. That is the contract-side regression
//                            `assertKeeperEoaPayoutBound` is designed to catch
//                            — a value path accidentally credited to the keeper
//                            EOA instead of the user/vault.
const ADVERSARIAL_PAYER_CREATION: Hex = '0x6002600c60003960026000f333ff';

const ADVERSARIAL_ABI = [
  { type: 'function', name: 'poke', inputs: [], outputs: [], stateMutability: 'nonpayable' },
] as const;

const TEST_KEEPER_PK: Hex = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'; // anvil[0]
const TEST_FUNDING_PK: Hex = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'; // anvil[1]

async function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, () => {
      const addr = srv.address();
      if (typeof addr === 'object' && addr) {
        const port = addr.port;
        srv.close(() => resolve(port));
      } else {
        srv.close(() => reject(new Error('failed to derive port')));
      }
    });
  });
}

async function waitForAnvil(rpcUrl: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_blockNumber', params: [] }),
      });
      if (r.ok) {
        const j = (await r.json()) as { result?: string };
        if (j.result) return;
      }
    } catch {
      // not ready yet
    }
    await new Promise((res) => setTimeout(res, 250));
  }
  throw new Error(`anvil did not become ready within ${timeoutMs}ms at ${rpcUrl}`);
}

async function rpcCall(rpcUrl: string, method: string, params: unknown[]): Promise<unknown> {
  const r = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const j = (await r.json()) as { result?: unknown; error?: { message: string } };
  if (j.error) throw new Error(`${method} failed: ${j.error.message}`);
  return j.result;
}

test('adversarial keeper sim: contract paying msg.sender trips the payout-bound circuit breaker on a Base mainnet fork', async (t) => {
  if (!BASE_RPC) {
    t.skip('BASE_MAINNET_RPC_URL not set — skipping fork-pinned adversarial sim');
    return;
  }

  const port = await findFreePort();
  const rpcUrl = `http://127.0.0.1:${port}`;
  // anvil preserves the source-fork chainId (8453 for Base mainnet) by default,
  // matching viem's `base` chain. The fork pins state to live Base mainnet at
  // the fork block; signer + chain-receiver chainIds align as on real mainnet.
  const anvilArgs = ['--fork-url', BASE_RPC, '--port', String(port)];
  if (FORK_BLOCK) anvilArgs.push('--fork-block-number', FORK_BLOCK);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-keeper-pb-fork-'));
  const breakerStatePath = path.join(tmpDir, 'circuit_breaker.json');

  let anvil: ChildProcess | null = null;
  try {
    anvil = spawn('anvil', anvilArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
    const anvilStdout: string[] = [];
    const anvilStderr: string[] = [];
    anvil.stdout?.on('data', (chunk: Buffer) => {
      anvilStdout.push(chunk.toString());
    });
    anvil.stderr?.on('data', (chunk: Buffer) => {
      anvilStderr.push(chunk.toString());
    });
    anvil.on('error', (err) => {
      console.error(`anvil spawn error: ${(err as Error).message}`);
    });
    try {
      await waitForAnvil(rpcUrl, 90_000);
    } catch (e) {
      console.error(`anvil stdout:\n${anvilStdout.join('')}`);
      console.error(`anvil stderr:\n${anvilStderr.join('')}`);
      throw e;
    }

    const keeperAccount = privateKeyToAccount(TEST_KEEPER_PK);
    const fundingAccount = privateKeyToAccount(TEST_FUNDING_PK);

    const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });
    const fundingWallet = createWalletClient({
      chain: base,
      transport: http(rpcUrl),
      account: fundingAccount,
    });
    const keeperWallet = createWalletClient({
      chain: base,
      transport: http(rpcUrl),
      account: keeperAccount,
    });

    // Snapshot keeper EOA on a known balance so the post-tx delta is deterministic.
    const keeperStartingWei = parseEther('5');
    await rpcCall(rpcUrl, 'anvil_setBalance', [
      keeperAccount.address,
      `0x${keeperStartingWei.toString(16)}`,
    ]);
    const fundingStartingWei = parseEther('5');
    await rpcCall(rpcUrl, 'anvil_setBalance', [
      fundingAccount.address,
      `0x${fundingStartingWei.toString(16)}`,
    ]);

    // Deploy AdversarialPayer from the funding account.
    const deployHash = await fundingWallet.sendTransaction({
      data: ADVERSARIAL_PAYER_CREATION,
      to: null,
    });
    const deployReceipt = await publicClient.waitForTransactionReceipt({ hash: deployHash });
    const adversaryAddr = (deployReceipt.contractAddress ?? '0x0') as Address;
    assert.notEqual(
      adversaryAddr,
      '0x0',
      'AdversarialPayer deployment did not return a contract address',
    );

    const deployedRuntime = await publicClient.getCode({ address: adversaryAddr });
    assert.equal(
      deployedRuntime,
      '0x33ff',
      `deployed runtime must be CALLER+SELFDESTRUCT; got: ${deployedRuntime}`,
    );

    // Fund the contract with 1 ETH via anvil_setBalance — a plain `value`
    // transfer would invoke the runtime (CALLER+SELFDESTRUCT) and immediately
    // drain back to the sender. Setting the balance directly bypasses code
    // execution, leaving the funded ETH waiting for the keeper's `poke()` call.
    await rpcCall(rpcUrl, 'anvil_setBalance', [adversaryAddr, `0x${parseEther('1').toString(16)}`]);
    const contractBal = await publicClient.getBalance({ address: adversaryAddr });
    assert.equal(
      contractBal,
      parseEther('1'),
      `AdversarialPayer must hold 1 ETH after funding; held ${contractBal}`,
    );

    const config = {
      pauseFilePath: path.join(tmpDir, 'PAUSED'),
      dryRun: false,
      allowTxWhilePending: true,
      txGasLimitMultiplierBps: 11_000,
      txMaxFeePerGasWei: null,
      txMaxPriorityFeePerGasWei: null,
      txMaxGasLimit: null,
      txMaxTotalFeeWei: null,
      txConfirmations: 1,
      txReceiptTimeoutMs: 30_000,
      circuitBreakerEnabled: true,
      circuitBreakerStatePath: breakerStatePath,
      circuitBreakerMaxFailures: 1,
      circuitBreakerCooldownMs: 60_000,
      deployment: 'fork-adversarial',
      alertWebhookUrl: '',
    } as any;

    const logBuf: string[] = [];
    const logFn = (msg: string) => logBuf.push(msg);

    const result = await sendContractTx({
      config,
      publicClient,
      walletClient: keeperWallet,
      account: keeperAccount,
      address: adversaryAddr,
      abi: ADVERSARIAL_ABI as any,
      functionName: 'poke',
      args: [],
      log: logFn,
    } as any);

    assert.equal(result.ok, true, `tx must confirm on-chain. log:\n${logBuf.join('\n')}`);
    if (result.ok) {
      assert.notEqual(
        result.payoutBoundViolation,
        null,
        `payout-bound audit must fire. log:\n${logBuf.join('\n')}`,
      );
      assert.match(
        result.payoutBoundViolation!.reason,
        /(received|outflow|less than (gasSpent|totalCost))/,
        `unexpected violation reason: ${result.payoutBoundViolation!.reason}`,
      );
    }

    // The circuit-breaker JSON state is cleared by `recordTxSuccess`, which
    // runs after the payout-bound audit because the on-chain tx itself
    // confirmed (the audit reports a contract-side regression, not a tx
    // failure). The PAUSE FILE is the persistent operational signal that
    // halts the keeper — `recordTxFailure` writes it when the breaker trips,
    // and `recordTxSuccess` does NOT remove it. Operators must clear the
    // pause file by hand after diagnosing the violation.
    const pauseFileExists = fs.existsSync(config.pauseFilePath);
    assert.equal(
      pauseFileExists,
      true,
      `pause file must exist after a payout-bound violation tripped the breaker (path=${config.pauseFilePath}). audit log:\n${logBuf.join('\n')}`,
    );
    const pauseFileContents = fs.readFileSync(config.pauseFilePath, 'utf8');
    assert.match(
      pauseFileContents,
      /circuit breaker tripped/,
      `pause file must record the breaker trip reason. contents=${pauseFileContents}`,
    );
    assert.match(
      pauseFileContents,
      /payout_bound_violation/,
      `pause file must reference the payout-bound violation as the trip cause. contents=${pauseFileContents}`,
    );

    const breakerState = loadCircuitBreakerState(breakerStatePath);
    // After `recordTxSuccess` resets the JSON, `lastFailureAtUtc` is the
    // surviving evidence that `recordTxFailure` ran. Assert it is set and
    // strictly precedes `lastSuccessAtUtc` (failure-then-success ordering).
    assert.notEqual(
      breakerState.lastFailureAtUtc,
      null,
      `lastFailureAtUtc must be set (proves recordTxFailure ran). state=${JSON.stringify(breakerState)}`,
    );
    assert.notEqual(
      breakerState.lastSuccessAtUtc,
      null,
      `lastSuccessAtUtc must be set (the on-chain tx confirmed). state=${JSON.stringify(breakerState)}`,
    );

    // Surface the full audit log + state evidence to the runner so the
    // archive captures the forensic detail.
    console.log(`adversarial-fork-sim audit log:\n${logBuf.join('\n')}`);
    console.log(
      `breaker state after one violation (post recordTxSuccess reset): ${JSON.stringify(breakerState, null, 2)}`,
    );
    console.log(`pause file contents:\n${pauseFileContents}`);
  } finally {
    if (anvil) {
      anvil.kill('SIGTERM');
      await new Promise((res) => setTimeout(res, 500));
      if (!anvil.killed) anvil.kill('SIGKILL');
    }
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
