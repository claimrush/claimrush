#!/usr/bin/env node
/**
 * Pre-unlock dry-run for GenesisLPVault24M.withdrawLp().
 *
 * Default mode: spawns an Anvil fork of the network recorded in the
 * deployment manifest, impersonates the immutable lpWithdrawRecipient,
 * warps past unlockTime, and executes withdrawLp() against the live
 * deployed vault bytecode. Reports the LP and fee-token deltas the
 * recipient would receive at unlock, plus invariant checks.
 *
 * Attach mode (--attach <url>): skips the internal Anvil spawn and runs
 * against an externally-managed Anvil instance already populated with
 * the post-genesis state (e.g. the T-15min fork rehearsal that already
 * ran FinalizeGenesis.s.sol against a forked-mainnet anvil). The script
 * does NOT teardown that anvil; its lifecycle stays with the caller.
 *
 * Usage (Base mainnet, default mode — informational, post-broadcast):
 *   BASE_MAINNET_RPC_URL=<rpc-url> node scripts/genesis_lp_withdraw_dry_run.mjs
 *
 * Usage (T-15min pre-broadcast gate, attach mode):
 *   anvil --fork-url $RPC_URL --port 8545 --chain-id 8453 &
 *   # run FinalizeGenesis.s.sol against http://localhost:8545 ...
 *   node scripts/genesis_lp_withdraw_dry_run.mjs --attach http://localhost:8545
 *
 * Usage (Base Sepolia, default mode — note: Sepolia uses a testnet mock
 * pool that does not implement Aerodrome v2 fee views, so the script
 * exercises only structural invariants):
 *   BASE_SEPOLIA_RPC_URL=<rpc-url> node scripts/genesis_lp_withdraw_dry_run.mjs \
 *     --manifest deployments/base_sepolia.json
 *
 * Flags:
 *   --manifest <path>   Deployment manifest path. Default: deployments/base_mainnet.json
 *   --attach <url>      Use an existing Anvil at <url> instead of spawning one. Skips
 *                       the BASE_*_RPC_URL env check and leaves the externally-owned
 *                       Anvil running on exit.
 *   --port <number>     Local Anvil port. Default: 8546. Ignored under --attach.
 *   --fork-block <n>    Pin the fork to a specific block (recommended for repro).
 *                       Ignored under --attach.
 *   --rpc <url>         RPC URL to fork from. Default: $BASE_MAINNET_RPC_URL or
 *                       $BASE_SEPOLIA_RPC_URL depending on the manifest chainId.
 *                       Ignored under --attach.
 *   --json              Emit a machine-readable JSON summary on stdout.
 *
 * Requires: foundry (`anvil`, `cast`) on PATH.
 */

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { readJsonFileSafe } from './lib/readJsonFileSafe.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');

const ARGS = parseArgs(process.argv.slice(2));
const MANIFEST_PATH = resolve(REPO_ROOT, ARGS.manifest ?? 'deployments/base_mainnet.json');
const ATTACH_URL = typeof ARGS.attach === 'string' ? ARGS.attach.trim() : '';
const ANVIL_PORT = Number.parseInt(ARGS.port ?? '8546', 10);
const FORK_BLOCK = ARGS['fork-block'] ? Number.parseInt(ARGS['fork-block'], 10) : null;
const JSON_OUT = Boolean(ARGS.json);

if (!ATTACH_URL) {
  if (!Number.isFinite(ANVIL_PORT) || ANVIL_PORT < 1024 || ANVIL_PORT > 65535) {
    fail(`Invalid --port ${ARGS.port}. Must be 1024-65535.`);
  }
} else if (!/^https?:\/\//.test(ATTACH_URL)) {
  fail(`Invalid --attach ${ATTACH_URL}. Must be an http(s):// URL.`);
}

const RPC = ATTACH_URL || `http://127.0.0.1:${ANVIL_PORT}`;

let anvilProc = null;
let tmpDir = null;
let FORK_URL = '';
let FORK_CHAIN_ID = 8453;

process.on('exit', cleanup);
process.on('SIGINT', () => {
  cleanup();
  process.exit(130);
});
process.on('SIGTERM', () => {
  cleanup();
  process.exit(143);
});

main().catch((err) => {
  const msg = err instanceof Error ? err.message : String(err);
  emitFailure({ phase: 'unexpected', message: msg });
  process.exit(1);
});

async function main() {
  const manifest = loadManifest(MANIFEST_PATH);
  const chainId = Number(manifest?.chainId ?? 8453);
  if (!Number.isFinite(chainId) || chainId <= 0) {
    fail(`Invalid chainId in manifest: ${manifest?.chainId}`);
  }
  FORK_CHAIN_ID = chainId;

  if (!ATTACH_URL) {
    const envForChain =
      chainId === 8453
        ? 'BASE_MAINNET_RPC_URL'
        : chainId === 84532
          ? 'BASE_SEPOLIA_RPC_URL'
          : null;
    FORK_URL = (ARGS.rpc ?? (envForChain ? process.env[envForChain] : '') ?? '').trim();
    if (!FORK_URL) {
      const hint = envForChain
        ? `Set ${envForChain} or pass --rpc <url>.`
        : 'Pass --rpc <url> (no canonical env var for this chainId).';
      fail(`RPC URL not set for chainId ${chainId}. ${hint}`);
    }
  }

  const vaultAddr = requireAddress(
    manifest?.contracts?.GenesisLPVault24M?.address,
    'contracts.GenesisLPVault24M.address',
  );

  if (ATTACH_URL) {
    await assertAttachedRpcReachable(RPC);
  } else {
    startAnvil();
    await waitForRpc(RPC);
  }

  const vault = readVaultState(vaultAddr);
  const pool = readPoolState(vault.pool, vaultAddr);

  const recipient = vault.lpWithdrawRecipient;
  const now = currentTimestamp();
  let warpedTo = now;
  if (vault.unlockTime > 0n && Number(vault.unlockTime) >= now) {
    warpedTo = Number(vault.unlockTime) + 1;
    warpTime(warpedTo);
  }

  fundAccount(recipient, '0x8AC7230489E80000');
  impersonate(recipient);

  const preLp = uint(callRaw(pool.poolAddr, '0x70a08231' + encAddr(recipient)));
  const pre0 = uint(callRaw(pool.token0, '0x70a08231' + encAddr(recipient)));
  const pre1 = uint(callRaw(pool.token1, '0x70a08231' + encAddr(recipient)));

  const send = castSend(vaultAddr, 'withdrawLp()', recipient);

  const postLp = uint(callRaw(pool.poolAddr, '0x70a08231' + encAddr(recipient)));
  const post0 = uint(callRaw(pool.token0, '0x70a08231' + encAddr(recipient)));
  const post1 = uint(callRaw(pool.token1, '0x70a08231' + encAddr(recipient)));
  const vaultLpResidual = uint(callRaw(pool.poolAddr, '0x70a08231' + encAddr(vaultAddr)));

  const lpDelta = postLp - preLp;
  const token0Delta = post0 - pre0;
  const token1Delta = post1 - pre1;

  const summary = {
    ok: true,
    manifestPath: MANIFEST_PATH,
    fork: {
      chainId: FORK_CHAIN_ID,
      source: ATTACH_URL ? 'attached' : 'self-spawned',
      attachedTo: ATTACH_URL || null,
      forkBlock: FORK_BLOCK,
      warpedTo,
    },
    vault: {
      address: vaultAddr,
      pool: pool.poolAddr,
      lpWithdrawRecipient: vault.lpWithdrawRecipient,
      lockStartTime: vault.lockStartTime.toString(),
      unlockTime: vault.unlockTime.toString(),
      lpLockedAmount: vault.lpLockedAmount.toString(),
      lpBalancePreDryRun: pool.vaultLpBalance.toString(),
      pendingClaimable0PreDryRun: pool.claimable0.toString(),
      pendingClaimable1PreDryRun: pool.claimable1.toString(),
    },
    pool: {
      token0: pool.token0,
      token1: pool.token1,
      token0Symbol: pool.token0Symbol,
      token1Symbol: pool.token1Symbol,
      token0Decimals: pool.token0Decimals,
      token1Decimals: pool.token1Decimals,
    },
    dryRun: {
      txHash: send.txHash,
      gasUsed: send.gasUsed,
      lpTransferredWei: lpDelta.toString(),
      token0ForwardedWei: token0Delta.toString(),
      token1ForwardedWei: token1Delta.toString(),
      vaultLpResidualWei: vaultLpResidual.toString(),
    },
    invariantChecks: {
      lpTransferEqualsPreBalance: lpDelta === pool.vaultLpBalance && pool.vaultLpBalance > 0n,
      vaultDrained: vaultLpResidual === 0n,
      forwardedAtLeastOneToken: token0Delta > 0n || token1Delta > 0n,
    },
  };

  if (
    !summary.invariantChecks.lpTransferEqualsPreBalance ||
    !summary.invariantChecks.vaultDrained
  ) {
    summary.ok = false;
  }

  emit(summary);
  if (!summary.ok) process.exitCode = 1;
}

// --------- cli helpers ---------

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    if (key === 'json') {
      out.json = true;
      continue;
    }
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      out[key] = '';
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

function fail(msg) {
  emitFailure({ phase: 'precondition', message: msg });
  process.exit(1);
}

function emitFailure({ phase, message }) {
  if (JSON_OUT) {
    process.stdout.write(`${JSON.stringify({ ok: false, phase, error: message })}\n`);
  } else {
    process.stderr.write(`ERROR (${phase}): ${message}\n`);
  }
}

function emit(summary) {
  if (JSON_OUT) {
    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
    return;
  }
  process.stdout.write(formatHumanSummary(summary));
}

function formatHumanSummary(s) {
  const lines = [];
  lines.push('');
  lines.push('== Genesis LP withdrawal dry-run ==');
  lines.push(`Manifest:           ${s.manifestPath}`);
  lines.push(
    `Fork:               chainId ${s.fork.chainId} (${s.fork.source}${s.fork.source === 'attached' ? ` ${s.fork.attachedTo}` : ''})${s.fork.forkBlock != null ? ` @ block ${s.fork.forkBlock}` : ''}`,
  );
  lines.push(`Warped to:          ${new Date(s.fork.warpedTo * 1000).toISOString()}`);
  lines.push('');
  lines.push(`Vault:              ${s.vault.address}`);
  lines.push(`Pool:               ${s.vault.pool}`);
  lines.push(`Recipient:          ${s.vault.lpWithdrawRecipient}`);
  lines.push(`Lock start:         ${formatTs(s.vault.lockStartTime)}`);
  lines.push(`Unlock time:        ${formatTs(s.vault.unlockTime)}`);
  lines.push(`LP locked snapshot: ${s.vault.lpLockedAmount} wei`);
  lines.push(`LP balance pre:     ${s.vault.lpBalancePreDryRun} wei`);
  lines.push(
    `Claimable0 pre:     ${s.vault.pendingClaimable0PreDryRun} wei (${s.pool.token0Symbol})`,
  );
  lines.push(
    `Claimable1 pre:     ${s.vault.pendingClaimable1PreDryRun} wei (${s.pool.token1Symbol})`,
  );
  lines.push('');
  lines.push('-- Dry-run result --');
  lines.push(`Tx hash:            ${s.dryRun.txHash ?? '(not captured)'}`);
  lines.push(`Gas used:           ${s.dryRun.gasUsed ?? '(not captured)'}`);
  lines.push(`LP transferred:     ${s.dryRun.lpTransferredWei} wei`);
  lines.push(
    `${s.pool.token0Symbol} forwarded:    ${s.dryRun.token0ForwardedWei} wei (decimals=${s.pool.token0Decimals})`,
  );
  lines.push(
    `${s.pool.token1Symbol} forwarded:    ${s.dryRun.token1ForwardedWei} wei (decimals=${s.pool.token1Decimals})`,
  );
  lines.push(`Vault LP residual:  ${s.dryRun.vaultLpResidualWei} wei`);
  lines.push('');
  lines.push('-- Invariants --');
  lines.push(
    `  LP transfer == pre-balance:  ${s.invariantChecks.lpTransferEqualsPreBalance ? 'PASS' : 'FAIL'}`,
  );
  lines.push(`  Vault drained:               ${s.invariantChecks.vaultDrained ? 'PASS' : 'FAIL'}`);
  lines.push(
    `  Forwarded >= 1 fee token:    ${s.invariantChecks.forwardedAtLeastOneToken ? 'PASS' : 'INFO (no fees accrued yet)'}`,
  );
  lines.push('');
  lines.push(s.ok ? 'RESULT: PASS' : 'RESULT: FAIL');
  lines.push('');
  return lines.join('\n');
}

// --------- manifest + addresses ---------

function loadManifest(path) {
  if (!existsSync(path)) {
    fail(`Manifest not found: ${path}`);
  }
  try {
    return readJsonFileSafe(path, { label: 'deployment manifest', maxBytes: 4 * 1024 * 1024 });
  } catch (err) {
    fail(err instanceof Error ? err.message : String(err));
    return null;
  }
}

function requireAddress(value, ctx) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    fail(`${ctx}: expected 0x-prefixed 20-byte address, got ${value}`);
  }
  if (/^0x0{40}$/i.test(value)) {
    fail(
      `${ctx} is the zero address. The manifest at ${MANIFEST_PATH} has not yet recorded a deployed ${ctx.split('.').pop()}. Run after the next broadcast records real addresses, or point --manifest at a different network manifest.`,
    );
  }
  return value;
}

// --------- anvil ---------

function startAnvil() {
  tmpDir = mkdtempSync(join(tmpdir(), 'claimrush-genesis-lp-dry-run-'));

  const args = [
    '--host',
    '127.0.0.1',
    '--port',
    String(ANVIL_PORT),
    '--chain-id',
    String(FORK_CHAIN_ID),
    '--gas-limit',
    '60000000',
    '--fork-url',
    FORK_URL,
  ];
  if (FORK_BLOCK != null) {
    args.push('--fork-block-number', String(FORK_BLOCK));
  }

  anvilProc = spawn('anvil', args, {
    stdio: ['ignore', 'ignore', 'ignore'],
    detached: false,
  });
  anvilProc.on('error', (err) => {
    fail(`Failed to spawn anvil: ${err.message}. Is Foundry installed and on PATH?`);
  });
}

async function waitForRpc(rpc, attempts = 100) {
  for (let i = 0; i < attempts; i++) {
    const r = spawnSync('cast', ['chain-id', '--rpc-url', rpc], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (r.status === 0) return;
    await sleep(100);
  }
  fail(`Anvil did not start on ${rpc} within ${attempts * 100}ms.`);
}

async function assertAttachedRpcReachable(rpc) {
  const r = spawnSync('cast', ['chain-id', '--rpc-url', rpc], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (r.status !== 0) {
    fail(
      `--attach ${rpc} is not reachable: ${(r.stderr || r.stdout || '').trim()}. Start Anvil first, then re-run with --attach <url>.`,
    );
  }
  const attachedChainId = Number(BigInt(r.stdout.trim()));
  if (Number.isFinite(attachedChainId) && attachedChainId !== FORK_CHAIN_ID) {
    fail(
      `--attach ${rpc} reports chainId ${attachedChainId}, but the manifest pins chainId ${FORK_CHAIN_ID}. Fork the right network before attaching.`,
    );
  }
}

function fundAccount(addr, weiHex) {
  rpc('anvil_setBalance', [addr, weiHex]);
}

function impersonate(addr) {
  rpc('anvil_impersonateAccount', [addr]);
}

function warpTime(unixSeconds) {
  rpc('evm_setNextBlockTimestamp', [unixSeconds]);
  rpc('evm_mine', []);
}

function currentTimestamp() {
  const tsHex = rpc('eth_getBlockByNumber', ['latest', false])?.timestamp ?? '0x0';
  const n = Number.parseInt(tsHex, 16);
  return Number.isFinite(n) && n > 0 ? n : Math.floor(Date.now() / 1000);
}

// --------- vault + pool reads ---------

function readVaultState(vaultAddr) {
  return {
    pool: requireAddress(callAddress(vaultAddr, 'pool()'), 'vault.pool()'),
    unlockTime: callUint(vaultAddr, 'unlockTime()'),
    lockStartTime: callUint(vaultAddr, 'lockStartTime()'),
    lpLockedAmount: callUint(vaultAddr, 'lpLockedAmount()'),
    lpWithdrawRecipient: requireAddress(
      callAddress(vaultAddr, 'lpWithdrawRecipient()'),
      'vault.lpWithdrawRecipient()',
    ),
  };
}

function readPoolState(poolAddr, vaultAddr) {
  const token0 = requireAddress(callAddress(poolAddr, 'token0()'), 'pool.token0()');
  const token1 = requireAddress(callAddress(poolAddr, 'token1()'), 'pool.token1()');
  return {
    poolAddr,
    token0,
    token1,
    token0Symbol: readErc20String(token0, 'symbol()') ?? 'TOKEN0',
    token1Symbol: readErc20String(token1, 'symbol()') ?? 'TOKEN1',
    token0Decimals: readErc20Uint8(token0, 'decimals()'),
    token1Decimals: readErc20Uint8(token1, 'decimals()'),
    vaultLpBalance: callUint(poolAddr, 'balanceOf(address)', [vaultAddr]),
    claimable0: tryCallUint(poolAddr, 'claimable0(address)', [vaultAddr]),
    claimable1: tryCallUint(poolAddr, 'claimable1(address)', [vaultAddr]),
  };
}

function tryCallUint(to, sig, args = []) {
  const r = spawnSync(
    'cast',
    ['call', to, sig, ...args.map(String), '--rpc-url', RPC],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    if (!JSON_OUT) {
      process.stderr.write(
        `WARN: ${to} ${sig} reverted; reporting 0 (pool may not implement Aerodrome v2 fee views).\n`,
      );
    }
    return 0n;
  }
  const out = r.stdout.trim();
  if (!out || out === '0x') return 0n;
  try {
    return BigInt(out);
  } catch {
    return 0n;
  }
}

function readErc20String(addr, sig) {
  const r = spawnSync(
    'cast',
    ['call', addr, sig, '--rpc-url', RPC],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) return null;
  const out = r.stdout.trim();
  if (!out || out === '0x') return null;
  return decodeAbiString(out);
}

function readErc20Uint8(addr, sig) {
  const r = spawnSync('cast', ['call', addr, sig, '--rpc-url', RPC], { encoding: 'utf8' });
  if (r.status !== 0) return 18;
  const out = r.stdout.trim();
  if (!out || out === '0x') return 18;
  try {
    return Number(BigInt(out));
  } catch {
    return 18;
  }
}

function decodeAbiString(hex) {
  try {
    const body = hex.startsWith('0x') ? hex.slice(2) : hex;
    if (body.length === 64) {
      const buf = Buffer.from(body, 'hex');
      let end = buf.length;
      while (end > 0 && buf[end - 1] === 0) end--;
      const s = buf.slice(0, end).toString('utf8');
      return s || null;
    }
    const len = Number.parseInt(body.slice(64, 128), 16);
    if (!Number.isFinite(len) || len <= 0 || len > 256) return null;
    const data = body.slice(128, 128 + len * 2);
    return Buffer.from(data, 'hex').toString('utf8');
  } catch {
    return null;
  }
}

// --------- cast helpers ---------

function callAddress(to, sig, args = []) {
  const r = spawnSync(
    'cast',
    ['call', to, sig, ...args.map(String), '--rpc-url', RPC],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    fail(`cast call ${to} ${sig} failed: ${r.stderr || r.stdout}`);
  }
  const out = r.stdout.trim();
  if (!out || out === '0x') return null;
  // cast returns the address as a hex word (left-padded). Take the last 40 hex chars.
  const body = out.startsWith('0x') ? out.slice(2) : out;
  if (body.length === 64) {
    return '0x' + body.slice(24);
  }
  return out;
}

function callUint(to, sig, args = []) {
  const r = spawnSync(
    'cast',
    ['call', to, sig, ...args.map(String), '--rpc-url', RPC],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    fail(`cast call ${to} ${sig} failed: ${r.stderr || r.stdout}`);
  }
  const out = r.stdout.trim();
  if (!out || out === '0x') return 0n;
  try {
    return BigInt(out);
  } catch {
    return 0n;
  }
}

function callRaw(to, data) {
  const r = spawnSync('cast', ['rpc', 'eth_call', JSON.stringify({ to, data }), 'latest', '--rpc-url', RPC], {
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    fail(`cast rpc eth_call failed: ${r.stderr || r.stdout}`);
  }
  const out = r.stdout.trim();
  if (!out) return '0x';
  try {
    const parsed = JSON.parse(out);
    return typeof parsed === 'string' ? parsed : '0x';
  } catch {
    return out;
  }
}

function uint(hex) {
  if (!hex || hex === '0x') return 0n;
  try {
    return BigInt(hex);
  } catch {
    return 0n;
  }
}

function encAddr(addr) {
  return addr.replace(/^0x/, '').toLowerCase().padStart(64, '0');
}

function castSend(to, sig, from) {
  const r = spawnSync(
    'cast',
    [
      'send',
      to,
      sig,
      '--rpc-url',
      RPC,
      '--from',
      from,
      '--unlocked',
      '--json',
    ],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    fail(`cast send ${sig} from ${from} failed: ${r.stderr || r.stdout}`);
  }
  const out = r.stdout.trim();
  try {
    const obj = JSON.parse(out);
    return {
      txHash: obj.transactionHash ?? obj.hash ?? null,
      gasUsed: obj.gasUsed ?? null,
    };
  } catch {
    return { txHash: out || null, gasUsed: null };
  }
}

function rpc(method, params) {
  const args = ['rpc', method];
  for (const p of params) {
    if (typeof p === 'string') args.push(p);
    else if (typeof p === 'boolean') args.push(p ? 'true' : 'false');
    else if (typeof p === 'number') args.push(String(p));
    else args.push(JSON.stringify(p));
  }
  args.push('--rpc-url', RPC);

  const r = spawnSync('cast', args, { encoding: 'utf8' });
  if (r.status !== 0) {
    fail(`cast rpc ${method} failed: ${r.stderr || r.stdout}`);
  }
  const out = r.stdout.trim();
  if (!out) return null;
  try {
    return JSON.parse(out);
  } catch {
    return out;
  }
}

function sleep(ms) {
  return new Promise((resolveFn) => setTimeout(resolveFn, ms));
}

function formatTs(secStr) {
  const n = Number(secStr);
  if (!Number.isFinite(n) || n <= 0) return '(not started)';
  return new Date(n * 1000).toISOString();
}

function cleanup() {
  if (anvilProc) {
    try {
      anvilProc.kill('SIGTERM');
    } catch {
      /* ignore */
    }
    anvilProc = null;
  }
  if (tmpDir) {
    try {
      rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
    tmpDir = null;
  }
}
