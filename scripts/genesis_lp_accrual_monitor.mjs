#!/usr/bin/env node
/**
 * Quarterly accrual monitor for GenesisLPVault24M.
 *
 * Read-only view calls against the live network. Records the vault's LP
 * balance plus per-side Aerodrome `claimable0(vault)` / `claimable1(vault)`
 * snapshots to a JSONL log. Designed to run on a cron schedule alongside
 * the live deployment so a missing or stuck fee accrual surfaces months
 * before the 24-month unlock.
 *
 * Usage:
 *   BASE_MAINNET_RPC_URL=<rpc-url> node scripts/genesis_lp_accrual_monitor.mjs
 *
 * Flags:
 *   --manifest <path>     Deployment manifest. Default: deployments/base_mainnet.json
 *   --log <path>          Output JSONL log. Default: monitoring/genesis-lp-accrual.jsonl
 *   --rpc <url>           RPC URL override. Default: $BASE_MAINNET_RPC_URL
 *   --print-only          Skip writing to the log; emit the snapshot to stdout only.
 *   --threshold-claim     Minimum CLAIM accrual since last snapshot to surface as
 *                         a "delta" alert (wei, decimal). Default: 0.
 *   --threshold-eth       Minimum WETH accrual since last snapshot to surface as
 *                         a "delta" alert (wei, decimal). Default: 0.
 *
 * Exit code:
 *   0  Snapshot recorded and within thresholds.
 *   1  RPC / contract read failure (snapshot NOT appended).
 *   2  Snapshot recorded but a delta threshold was breached (advisory).
 *
 * Cron (quarterly, first of every third month at 12:00 UTC):
 *   `0 12 1 ★/3 * BASE_MAINNET_RPC_URL=... /usr/bin/node \
 *     /opt/claimrush/scripts/genesis_lp_accrual_monitor.mjs`
 *   (Replace ★ with an asterisk; documented this way to avoid closing the
 *   JSDoc comment block with a literal asterisk-slash.)
 */

import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { readJsonFileSafe } from './lib/readJsonFileSafe.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');

const ARGS = parseArgs(process.argv.slice(2));
const MANIFEST_PATH = resolve(REPO_ROOT, ARGS.manifest ?? 'deployments/base_mainnet.json');
const LOG_PATH = resolve(REPO_ROOT, ARGS.log ?? 'monitoring/genesis-lp-accrual.jsonl');
const PRINT_ONLY = Boolean(ARGS['print-only']);
const RPC = (ARGS.rpc ?? process.env.BASE_MAINNET_RPC_URL ?? '').trim();
const THRESHOLD_CLAIM = parseBigIntOrZero(ARGS['threshold-claim']);
const THRESHOLD_ETH = parseBigIntOrZero(ARGS['threshold-eth']);

if (!RPC) {
  fail('No RPC URL: set BASE_MAINNET_RPC_URL or pass --rpc <url>.');
}

const manifest = loadManifest(MANIFEST_PATH);
const vaultAddr = requireAddress(
  manifest?.contracts?.GenesisLPVault24M?.address,
  'contracts.GenesisLPVault24M.address',
);

const now = Math.floor(Date.now() / 1000);

let vault;
let pool;
try {
  vault = {
    pool: requireAddress(callAddress(vaultAddr, 'pool()'), 'vault.pool()'),
    unlockTime: callUint(vaultAddr, 'unlockTime()'),
    lockStartTime: callUint(vaultAddr, 'lockStartTime()'),
    lpLockedAmount: callUint(vaultAddr, 'lpLockedAmount()'),
    lpWithdrawRecipient: requireAddress(
      callAddress(vaultAddr, 'lpWithdrawRecipient()'),
      'vault.lpWithdrawRecipient()',
    ),
  };

  pool = {
    address: vault.pool,
    token0: requireAddress(callAddress(vault.pool, 'token0()'), 'pool.token0()'),
    token1: requireAddress(callAddress(vault.pool, 'token1()'), 'pool.token1()'),
    vaultLpBalance: callUint(vault.pool, 'balanceOf(address)', [vaultAddr]),
    claimable0: callUint(vault.pool, 'claimable0(address)', [vaultAddr]),
    claimable1: callUint(vault.pool, 'claimable1(address)', [vaultAddr]),
  };

  pool.token0Symbol = readErc20String(pool.token0, 'symbol()') ?? 'TOKEN0';
  pool.token1Symbol = readErc20String(pool.token1, 'symbol()') ?? 'TOKEN1';
  pool.token0Decimals = readErc20Uint(pool.token0, 'decimals()');
  pool.token1Decimals = readErc20Uint(pool.token1, 'decimals()');
} catch (err) {
  fail(err instanceof Error ? err.message : String(err));
}

const snapshot = {
  ts: now,
  iso: new Date(now * 1000).toISOString(),
  chain: 'base_mainnet',
  vault: vaultAddr,
  pool: pool.address,
  lpWithdrawRecipient: vault.lpWithdrawRecipient,
  lockStartTime: vault.lockStartTime.toString(),
  unlockTime: vault.unlockTime.toString(),
  lpLockedAmount: vault.lpLockedAmount.toString(),
  vaultLpBalance: pool.vaultLpBalance.toString(),
  token0: {
    address: pool.token0,
    symbol: pool.token0Symbol,
    decimals: pool.token0Decimals,
    claimableWei: pool.claimable0.toString(),
  },
  token1: {
    address: pool.token1,
    symbol: pool.token1Symbol,
    decimals: pool.token1Decimals,
    claimableWei: pool.claimable1.toString(),
  },
  daysUntilUnlock:
    vault.unlockTime > 0n ? Math.max(0, Math.floor((Number(vault.unlockTime) - now) / 86_400)) : null,
};

const prev = readLastSnapshot(LOG_PATH);
const delta = computeDelta(prev, snapshot);
if (delta) snapshot.delta = delta;

if (!PRINT_ONLY) {
  ensureDir(dirname(LOG_PATH));
  appendFileSync(LOG_PATH, `${JSON.stringify(snapshot)}\n`, { encoding: 'utf8' });
}

process.stdout.write(`${JSON.stringify(snapshot, null, 2)}\n`);

if (delta) {
  const d0 = BigInt(delta.token0ClaimableDeltaWei);
  const d1 = BigInt(delta.token1ClaimableDeltaWei);
  const threshold0 = guessThresholdForToken(pool.token0Symbol);
  const threshold1 = guessThresholdForToken(pool.token1Symbol);
  if (d0 < -threshold0 || d1 < -threshold1) {
    process.stderr.write(
      'ALERT: claimable balance decreased between snapshots. Investigate (fee claim, pool migration, or vault state change).\n',
    );
    process.exit(2);
  }
}

process.exit(0);

// --------- helpers ---------

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    if (key === 'print-only') {
      out['print-only'] = true;
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
  process.stderr.write(`ERROR: ${msg}\n`);
  process.exit(1);
}

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
      `${ctx} is the zero address in ${MANIFEST_PATH}. The vault has not yet been recorded for this network. Run after the next broadcast or pass --manifest <other-network>.json.`,
    );
  }
  return value;
}

function parseBigIntOrZero(raw) {
  if (!raw) return 0n;
  try {
    return BigInt(raw);
  } catch {
    return 0n;
  }
}

function callAddress(to, sig, args = []) {
  const r = spawnSync(
    'cast',
    ['call', to, sig, ...args.map(String), '--rpc-url', RPC],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    throw new Error(`cast call ${to} ${sig} failed: ${stripStderr(r)}`);
  }
  const out = r.stdout.trim();
  if (!out || out === '0x') return null;
  const body = out.startsWith('0x') ? out.slice(2) : out;
  if (body.length === 64) return `0x${body.slice(24)}`;
  return out;
}

function callUint(to, sig, args = []) {
  const r = spawnSync(
    'cast',
    ['call', to, sig, ...args.map(String), '--rpc-url', RPC],
    { encoding: 'utf8' },
  );
  if (r.status !== 0) {
    throw new Error(`cast call ${to} ${sig} failed: ${stripStderr(r)}`);
  }
  const out = r.stdout.trim();
  if (!out || out === '0x') return 0n;
  try {
    return BigInt(out);
  } catch {
    return 0n;
  }
}

function stripStderr(r) {
  return (r.stderr ?? '').toString().trim() || (r.stdout ?? '').toString().trim();
}

function readErc20String(addr, sig) {
  try {
    const r = spawnSync('cast', ['call', addr, sig, '--rpc-url', RPC], { encoding: 'utf8' });
    if (r.status !== 0) return null;
    const out = r.stdout.trim();
    if (!out || out === '0x') return null;
    return decodeAbiString(out);
  } catch {
    return null;
  }
}

function readErc20Uint(addr, sig) {
  try {
    const r = spawnSync('cast', ['call', addr, sig, '--rpc-url', RPC], { encoding: 'utf8' });
    if (r.status !== 0) return 18;
    const out = r.stdout.trim();
    if (!out || out === '0x') return 18;
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

function ensureDir(path) {
  if (!existsSync(path)) mkdirSync(path, { recursive: true });
}

function readLastSnapshot(path) {
  if (!existsSync(path)) return null;
  try {
    const size = statSync(path).size;
    const readBytes = Math.min(size, 64 * 1024);
    const buf = readFileSync(path);
    const tail = buf.slice(size - readBytes, size).toString('utf8');
    const lines = tail.split('\n').filter((l) => l.trim());
    if (!lines.length) return null;
    return JSON.parse(lines[lines.length - 1]);
  } catch {
    return null;
  }
}

function computeDelta(prev, curr) {
  if (!prev || prev.vault?.toLowerCase() !== curr.vault.toLowerCase()) return null;
  try {
    const prevClaimable0 = BigInt(prev.token0?.claimableWei ?? '0');
    const prevClaimable1 = BigInt(prev.token1?.claimableWei ?? '0');
    const currClaimable0 = BigInt(curr.token0.claimableWei);
    const currClaimable1 = BigInt(curr.token1.claimableWei);
    const prevLp = BigInt(prev.vaultLpBalance ?? '0');
    const currLp = BigInt(curr.vaultLpBalance);
    const dt = curr.ts - (prev.ts ?? curr.ts);
    return {
      sinceTs: prev.ts ?? curr.ts,
      sinceIso: prev.iso ?? curr.iso,
      elapsedSeconds: dt,
      token0ClaimableDeltaWei: (currClaimable0 - prevClaimable0).toString(),
      token1ClaimableDeltaWei: (currClaimable1 - prevClaimable1).toString(),
      lpBalanceDeltaWei: (currLp - prevLp).toString(),
    };
  } catch {
    return null;
  }
}

function guessThresholdForToken(symbol) {
  // Operator-facing alert thresholds. A fee claim by anyone would empty the
  // claimable slots, so a decrease is genuinely unexpected.
  if (typeof symbol !== 'string') return 0n;
  const upper = symbol.toUpperCase();
  if (upper === 'WETH' || upper === 'ETH') return THRESHOLD_ETH;
  if (upper === 'CLAIM') return THRESHOLD_CLAIM;
  return 0n;
}
