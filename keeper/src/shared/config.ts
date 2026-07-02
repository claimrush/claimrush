import path from 'node:path';
import { z } from 'zod';

import { parseBool, parseIntStrict } from './env.js';
import { getKeeperRoot } from './paths.js';
import { ensureDir } from './state.js';
import { clamp } from './utils.js';

// Deployment names are used in filesystem paths (state dir, lock file) and deployment manifest lookup.
// Restrict to a safe filename subset to prevent path traversal or accidental writes outside KEEPER_STATE_DIR.
const DEPLOYMENT_NAME_RE = /^[a-zA-Z0-9_.-]{1,64}$/;

function assertSafeDeploymentName(name: unknown): string {
  const s = String(name ?? '').trim();
  if (!s) {
    throw new Error('KEEPER_DEPLOYMENT missing (e.g. local, base_sepolia, base_mainnet)');
  }
  if (s === '.' || s === '..') {
    throw new Error('Invalid KEEPER_DEPLOYMENT: "." and ".." are not allowed');
  }
  if (!DEPLOYMENT_NAME_RE.test(s)) {
    throw new Error(
      `Invalid KEEPER_DEPLOYMENT: ${s}. Allowed characters: letters, numbers, "_", ".", "-" (max 64; no slashes)`,
    );
  }
  return s;
}

function isHttpUrl(url: string): boolean {
  return /^https?:\/\//i.test(String(url ?? '').trim());
}

// Hostnames that unambiguously identify a Base *mainnet* (chain 8453) RPC.
// Used by the deployment/RPC consistency guard below to fail closed when the
// operator points a staging (Base Sepolia / chain 84532) keeper at a mainnet
// provider — which would burn production Alchemy CUs and/or submit txs on
// the wrong chain.
//
// External operators can extend either list without forking this file by
// setting:
//   KEEPER_BASE_MAINNET_HOST_HINTS="rpc.mycompany.com,primary-rpc.base.local"
//   KEEPER_BASE_SEPOLIA_HOST_HINTS="sepolia-rpc.mycompany.com"
// The env values are comma/whitespace-separated, case-insensitive, matched
// as full hostnames or as the parent of `*.<host>` suffixes (same semantics
// as the baked-in list below). The baked-in list is the ClaimRush default
// set; it is always applied so that operators who do not set the env vars
// still get a safe guard.
const DEFAULT_BASE_MAINNET_HOST_HINTS = [
  'base-mainnet.g.alchemy.com',
  'mainnet.base.org',
  'base.gateway.tenderly.co',
  'base-rpc.publicnode.com',
  'rpc-proxy.claimru.sh',
];

const DEFAULT_BASE_SEPOLIA_HOST_HINTS = [
  'base-sepolia.g.alchemy.com',
  'sepolia.base.org',
  'base-sepolia-rpc.publicnode.com',
  'rpc-proxy-sepolia.claimru.sh',
];

function parseHostHintEnv(raw: string | undefined): string[] {
  if (!raw) return [];
  // Accept any of whitespace, comma, or semicolon as a delimiter. A typo
  // like `host1;host2` previously became a single opaque token, which then
  // silently failed to match any entry in the deployment↔RPC host hints
  // list (fail-open): the operator believed they had added two hosts, but
  // the consistency check would never hit. Supporting ';' makes that class
  // of typo a hard failure at config load time instead.
  return raw
    .split(/[\s,;]+/)
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0);
}

const BASE_MAINNET_HOST_HINTS = Array.from(
  new Set([
    ...DEFAULT_BASE_MAINNET_HOST_HINTS,
    ...parseHostHintEnv(process.env.KEEPER_BASE_MAINNET_HOST_HINTS),
  ]),
);

const BASE_SEPOLIA_HOST_HINTS = Array.from(
  new Set([
    ...DEFAULT_BASE_SEPOLIA_HOST_HINTS,
    ...parseHostHintEnv(process.env.KEEPER_BASE_SEPOLIA_HOST_HINTS),
  ]),
);

function hostnameOf(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

function assertDeploymentRpcConsistency(
  deployment: string,
  urls: Array<{ name: string; url: string | undefined }>,
): void {
  const norm = deployment.trim().toLowerCase();
  const isSepolia = norm === 'base_sepolia' || norm === 'basesepolia';
  const isMainnet = norm === 'base_mainnet' || norm === 'basemainnet';
  if (!isSepolia && !isMainnet) return;

  for (const { name, url } of urls) {
    const host = hostnameOf(url);
    if (!host) continue;

    if (isSepolia && BASE_MAINNET_HOST_HINTS.some((h) => host === h || host.endsWith(`.${h}`))) {
      throw new Error(
        `Refusing to start: KEEPER_DEPLOYMENT=${deployment} but ${name} points at a Base mainnet host (${host}). ` +
          'This would burn production RPC credits and/or submit txs on the wrong chain. ' +
          'Set the URL to the Sepolia proxy (https://rpc-proxy-sepolia.claimru.sh) ' +
          'or an otherwise Sepolia-specific endpoint.',
      );
    }

    if (isMainnet && BASE_SEPOLIA_HOST_HINTS.some((h) => host === h || host.endsWith(`.${h}`))) {
      throw new Error(
        `Refusing to start: KEEPER_DEPLOYMENT=${deployment} but ${name} points at a Base Sepolia host (${host}). ` +
          'Set the URL to the mainnet proxy (https://rpc-proxy.claimru.sh) ' +
          'or an otherwise mainnet-specific endpoint.',
      );
    }
  }
}

const HttpUrl = z
  .string()
  .url()
  .refine((u) => isHttpUrl(u), {
    message: 'must be an http(s) URL',
  });

const HexPrivateKey = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, 'KEEPER_PRIVATE_KEY must be a 0x-prefixed 32-byte hex string');

export interface KeeperConfig {
  deployment: string;
  publicRpcUrl: string | undefined;
  privateRpcUrl: string | undefined;
  /** Optional bearer auth header for the public (read) RPC. */
  publicRpcAuthToken: string | null;
  /** Optional bearer auth header for the private (write) RPC. */
  privateRpcAuthToken: string | null;
  /** RPC transport settings */
  publicRpcTimeoutMs: number;
  privateRpcTimeoutMs: number;
  rpcRetryCount: number;
  rpcBatchWaitMs: number;

  /**
   * Multicall3 deployment address.  Null means "use the canonical
   * `0xcA11bde05977b3631167028862bE2a173976CA11` deployment" (the default
   * CREATE2 address used on Base, Base Sepolia, and every other mainstream
   * chain).  Set KEEPER_MULTICALL3_ADDRESS to override, e.g. for a custom
   * testnet where Multicall3 was deployed at a different address.
   */
  multicall3Address: string | null;
  /** Optional block at which Multicall3 was deployed (enables viem's `blockCreated` hint). */
  multicall3BlockCreated: number | null;

  /**
   * Optional WebSocket endpoint used by the event-driven keeper
   * subscriptions (phase 4).  When unset, the keeper falls back to pure
   * polling.  Prefer `wss://`; on localhost `ws://` is permitted so the
   * keeper can subscribe to a co-located node.
   */
  wsUrl: string | null;
  /**
   * Optional secondary WebSocket endpoint used if the primary WS drops.
   * The keeper cycles primary → fallback → primary → … with exponential
   * backoff and a brief circuit-breaker between attempts.
   */
  wsUrlFallback: string | null;
  /**
   * Subset of hot tasks allowed to be triggered by WS events.  Defaults
   * to `["poke","sweep-market","sweep-listings","expire-offers"]` (i.e.
   * the full hot set).  Operators can narrow this list as a kill-switch
   * (`KEEPER_EVENT_DRIVEN_TASKS=""` disables event-driven execution
   * entirely; tasks keep running on their polling cadence).
   */
  eventDrivenTasks: string[];
  /**
   * Cadence of the catch-up safety-net scan.  Independent of the primary
   * polling cadence: the safety net performs narrow `eth_getLogs` calls
   * from the last WS-observed block to latest, and only widens to full
   * discovery when WS has been silent for >5 min.  Default 3600 s.
   */
  safetyNetIntervalSecs: number;
  /**
   * Grace period for a dropped WS connection before hot tasks fall back
   * to their fast polling cadence.  Reconnects are expected to complete
   * within seconds, so a few minutes of grace avoids oscillating the
   * schedule on transient blips.  Default 300 s.
   */
  wsDisconnectedGraceSecs: number;
  /**
   * Minimum delay (seconds) between successive event-driven runs of the
   * same hot task.  Protects against on-chain event spam (e.g. a burst
   * of listings/offers in one block) flooding the RPC provider with
   * back-to-back scans once the previous scan finishes.  Events that
   * arrive within the window are coalesced into a single deferred run.
   * Set to `0` to disable (runs fire as soon as the previous one ends).
   * Default 5 s — small enough to be imperceptible for legitimate events
   * (2-3 Base blocks) while capping spam-driven runs at 12/min per task.
   */
  eventMinRepeatSecs: number;
  privateKey: string | undefined;
  /** Optional safety rail: refuse to run if the derived account address does not match. */
  expectedAccountAddress: string | null;
  dryRun: boolean;
  /** Extra opt-in guard. Required when dryRun=false. */
  liveRun: boolean;
  allowUnsafeMinOut: boolean;
  allowUnsafeMinVeOut: boolean;

  /** Emergency / safety pause. If true, keeper will not submit transactions. */
  paused: boolean;
  /** Pause file path. If present on disk, keeper will not submit transactions. */
  pauseFilePath: string;

  /** Transaction safety rails */
  txConfirmations: number;
  txReceiptTimeoutMs: number;
  txMaxFeePerGasWei: bigint | null;
  txMaxPriorityFeePerGasWei: bigint | null;
  txMaxTotalFeeWei: bigint | null;
  txGasLimitMultiplierBps: number;
  /** Optional hard cap on gas limit per tx (gas units). */
  txMaxGasLimit: bigint | null;
  allowTxWhilePending: boolean;

  /** Global circuit breaker (auto-pause) */
  circuitBreakerEnabled: boolean;
  circuitBreakerMaxFailures: number;
  circuitBreakerCooldownMs: number;
  circuitBreakerStatePath: string;

  intervalSecs: number;
  /**
   * Cadence used when the keeper observes tier=`primary` on its RPC proxy
   * — i.e. when the public RPC endpoint is being served by our local L2
   * node.  Equal to `intervalSecs` by default (back-compat).
   */
  intervalSecsPrimary: number;
  /**
   * Cadence used when the keeper observes tier=`fallback` on its RPC proxy
   * — i.e. when the local node is down and reads are being served by
   * Alchemy (or any other non-index-0 upstream).  Stretched to relieve
   * Alchemy CU pressure during a local-node outage.  Defaults to
   * `max(intervalSecsPrimary, 1800)`.
   */
  intervalSecsFallback: number;
  daemonTasks: string[];
  daemonJitterBps: number;
  daemonLockWaitSecs: number;
  pokeIntervalSecs: number;
  sweepMarketIntervalSecs: number;
  sweepListingsIntervalSecs: number;
  expireOffersIntervalSecs: number;
  harvestStakingIntervalSecs: number;
  compoundShareholdersIntervalSecs: number;
  compoundLpIntervalSecs: number;
  checkpointBeforeExpiryIntervalSecs: number;
  deadlineSecs: number;
  maxOffers: number;
  maxListings: number;
  maxExpireOffers: number;
  slippageBpsStaking: number;
  compoundSlippageBpsShareholders: number;
  compoundSlippageBpsLp: number;
  compoundMaxUsersShareholders: number;
  compoundMaxUsersLp: number;
  compoundLookaheadUsers: number;
  compoundScanChunkBlocks: number;
  compoundShareholdersStartBlock: number | null;
  compoundLpStartBlock: number | null;
  compoundMaxGas: number;
  compoundLpMinReward: bigint;
  harvestStakingMinReward: bigint;
  marketScanChunkBlocks: number;
  marketStartBlockOverride: number | null;
  autoFurnaceBackoffEnabled: boolean;
  autoFurnacePreflightEnabled: boolean;
  autoFurnaceBackoffInitialMs: number;
  autoFurnaceBackoffMaxMs: number;
  autoFurnaceBackoffMultiplier: number;
  autoFurnaceBackoffJitterBps: number;
  listingsBackoffEnabled: boolean;
  listingsPreflightEnabled: boolean;
  listingsBackoffInitialMs: number;
  listingsBackoffMaxMs: number;
  listingsBackoffMultiplier: number;
  listingsBackoffJitterBps: number;
  listingsStartBlockOverride: number | null;
  expireOffersBackoffEnabled: boolean;
  expireOffersPreflightEnabled: boolean;
  expireOffersBackoffInitialMs: number;
  expireOffersBackoffMaxMs: number;
  expireOffersBackoffMultiplier: number;
  expireOffersBackoffJitterBps: number;
  stateDir: string;
  deploymentStateDir: string;
  statusPath: string;
  marketStatePath: string;
  listingsStatePath: string;
  expireOffersStatePath: string;
  compoundShareholdersStatePath: string;
  compoundLpStatePath: string;
  checkpointBeforeExpiryStatePath: string;
  // Optional per-task overrides (used with ?? fallback in task modules)
  checkpointBeforeExpiryStartBlock?: number | null;
  checkpointBeforeExpiryScanChunkBlocks?: number | null;
  checkpointBeforeExpiryWindowSecs?: number | null;
  checkpointBeforeExpiryMaxUsers?: number | null;
  pokeStaleThresholdSecs: number;
  pokeLpTickIntervalSecs: number;
  pokeMinPendingEthDelta: string;
  pokeStatePath: string;
  /**
   * Client-side chunk size (blocks) for the Takeover event scan that `poke`
   * runs each cycle.  Providers with strict `eth_getLogs` limits (e.g.
   * Alchemy free-tier caps Base Sepolia at ~10 blocks) will otherwise force
   * `getLogsWithAutoSplit` to bisect the range repeatedly after a keeper
   * downtime backlog, emitting `rpc getLogs too large` warnings.  Align this
   * with `KEEPER_MARKET_SCAN_CHUNK_BLOCKS` on constrained networks.
   */
  pokeTakeoverScanChunkBlocks: number;

  automaxBonusIntervalSecs: number;
  automaxBonusStatePath: string;
  automaxBonusStartBlock?: number | null;
  automaxBonusScanChunkBlocks?: number | null;
  automaxBonusMaxLocks?: number | null;
  automaxBonusMinReward: string;

  // Settlement window (opt-in keeper policy). Cadence is configurable via
  // settlementPeriodSecs: 86400 = daily (default), 604800 = weekly. The
  // day-of-week anchor (settlementDayUtc) only applies to weekly-multiple
  // periods; sub-week periods anchor to settlementHourUtc only.
  settlementEnabled: boolean;
  settlementPeriodSecs: number;
  settlementDayUtc: number;
  settlementHourUtc: number;
  settlementWindowDurationSecs: number;
  settlementTaskGapSecs: number;
  settlementRetryWindowSecs: number;
  settlementMaxDriftBps: number;
  settlementStatePath: string;

  // Per-user compound/bonus floors. Each defaults to settlementPeriodSecs so a
  // single cadence knob moves them in lockstep; override individually to
  // decouple a task from the master period.
  compoundShareholderMinCadenceSecs: number;
  /**
   * Per-user intra-day spread window (seconds) for compound-shareholders. A
   * deterministic per-user offset in `[0, this)` is added on top of the cadence
   * floor so synchronized users fan out across the day instead of compounding
   * in one batch. `0` disables spreading. Effective cadence becomes
   * `[floor, floor + spread)`.
   */
  compoundShareholderSpreadSecs: number;
  compoundLpMinCadenceSecs: number;
  automaxOwnerCooldownSecs: number;

  subgraphUrl: string | null;
  morningWindowHours: number;
  morningCachePath: string;

  lockPath: string;
  lockTtlMs: number;
  lockHeartbeatMs: number;

  /**
   * Optional secondary host-scoped advisory lock, keyed on (uid,
   * deployment), implemented via a Linux abstract UNIX socket.
   *
   * When set, the keeper must acquire BOTH this host-socket lock and
   * `lockPath` before it is allowed to start.  This defends against the
   * duplicate-instance footgun where two keeper processes on the same host
   * point at two different `KEEPER_STATE_DIR`s for the same
   * `KEEPER_DEPLOYMENT` (symlinks, relative paths, copied env files, hand-
   * rolled `nohup` daemons alongside a systemd unit, …) and therefore
   * silently bypass the per-state-dir lock.
   *
   * Abstract sockets are chosen over a file lock because systemd units
   * with `PrivateTmp=true` see a namespaced `/tmp` that is invisible to
   * other processes, so a filesystem-based host lock at `os.tmpdir()`
   * would fail to contend.  Abstract sockets are scoped by the host
   * network namespace only, which every keeper process shares.
   *
   * Defaults to `claimrush-keeper-<deployment>-<uid>`.  Set
   * `KEEPER_HOST_LOCK_NAME=""` (empty) to disable (not recommended).
   * Non-Linux platforms silently skip this lock at runtime.
   */
  hostLockName: string | null;

  /** Optional health server (daemon). Disabled when healthPort=0. */
  healthHost: string;
  healthPort: number;
  healthToken: string | null;

  alertWebhookUrl: string | null;

  /**
   * Low-gas alerting on the keeper EOA. When `gasBalanceMinWei` is non-null the
   * daemon periodically reads its own native-token balance and posts a
   * `keeper_low_gas_balance` alert (via `alertWebhookUrl`) whenever the balance
   * falls below this floor. Null disables the check entirely. The keeper never
   * pays itself — its balance only ever drops by tx gas — so a balance below a
   * sane floor means it is approaching the point where it can no longer land
   * maintenance txs and must be topped up.
   */
  gasBalanceMinWei: bigint | null;
  /** How often to read the EOA balance for the low-gas check (seconds). */
  gasBalanceCheckIntervalSecs: number;
  /**
   * Minimum gap between repeated low-gas alerts while the balance stays below
   * the floor (seconds). The first crossing alerts immediately; subsequent
   * re-alerts are throttled to this cadence to avoid an alert storm.
   */
  gasBalanceAlertRepeatSecs: number;
}

// ---------------------------------------------------------------------------
// Zod schema – validates the fully‐parsed config so missing or malformed
// values surface immediately at startup instead of mid-execution.
// ---------------------------------------------------------------------------

const KeeperConfigSchema = z.object({
  deployment: z
    .string()
    .regex(
      DEPLOYMENT_NAME_RE,
      'KEEPER_DEPLOYMENT must be a safe name (letters, numbers, _, ., -, max 64; no slashes)',
    )
    .refine((s) => s !== '.' && s !== '..', {
      message: 'KEEPER_DEPLOYMENT cannot be "." or ".."',
    }),

  publicRpcUrl: HttpUrl.optional(),
  privateRpcUrl: HttpUrl.optional(),
  publicRpcAuthToken: z.string().nullable(),
  privateRpcAuthToken: z.string().nullable(),

  publicRpcTimeoutMs: z.number().int().min(250).max(120_000),
  privateRpcTimeoutMs: z.number().int().min(250).max(120_000),
  rpcRetryCount: z.number().int().min(0).max(10),
  rpcBatchWaitMs: z.number().int().min(0).max(1_000),

  multicall3Address: z
    .string()
    .regex(/^0x[0-9a-fA-F]{40}$/, 'KEEPER_MULTICALL3_ADDRESS must be a 20-byte hex address')
    .nullable(),
  multicall3BlockCreated: z.number().int().nonnegative().nullable(),

  wsUrl: z
    .string()
    .url()
    .refine((u) => /^wss?:\/\//i.test(u), { message: 'must be a ws(s) URL' })
    .nullable(),
  wsUrlFallback: z
    .string()
    .url()
    .refine((u) => /^wss?:\/\//i.test(u), { message: 'must be a ws(s) URL' })
    .nullable(),
  eventDrivenTasks: z.array(z.string().min(1)),
  safetyNetIntervalSecs: z.number().int().min(60).max(86_400),
  wsDisconnectedGraceSecs: z.number().int().min(0).max(3_600),
  eventMinRepeatSecs: z.number().int().min(0).max(3_600),
  privateKey: HexPrivateKey.optional(),
  expectedAccountAddress: z
    .string()
    .regex(/^0x[0-9a-fA-F]{40}$/)
    .nullable(),

  dryRun: z.boolean(),
  liveRun: z.boolean(),
  allowUnsafeMinOut: z.boolean(),
  allowUnsafeMinVeOut: z.boolean(),

  paused: z.boolean(),
  pauseFilePath: z.string().min(1),

  txConfirmations: z.number().int().min(1).max(100),
  txReceiptTimeoutMs: z.number().int().min(5_000).max(3_600_000),
  txMaxFeePerGasWei: z.bigint().min(0n).nullable(),
  txMaxPriorityFeePerGasWei: z.bigint().min(0n).nullable(),
  txMaxTotalFeeWei: z.bigint().min(0n).nullable(),
  txGasLimitMultiplierBps: z.number().int().min(10_000).max(30_000),
  txMaxGasLimit: z.bigint().min(21_000n).nullable(),
  allowTxWhilePending: z.boolean(),

  circuitBreakerEnabled: z.boolean(),
  circuitBreakerMaxFailures: z.number().int().min(1).max(100),
  circuitBreakerCooldownMs: z.number().int().min(60_000).max(604_800_000),
  circuitBreakerStatePath: z.string().min(1),

  intervalSecs: z.number().int().min(10).max(86_400),
  intervalSecsPrimary: z.number().int().min(10).max(86_400),
  intervalSecsFallback: z.number().int().min(10).max(86_400),

  daemonTasks: z.array(z.string().min(1)).min(1),
  daemonJitterBps: z.number().int().min(0).max(5_000),
  daemonLockWaitSecs: z.number().int().min(0).max(3_600),

  pokeIntervalSecs: z.number().int().min(10).max(86_400),
  sweepMarketIntervalSecs: z.number().int().min(10).max(86_400),
  sweepListingsIntervalSecs: z.number().int().min(10).max(86_400),
  expireOffersIntervalSecs: z.number().int().min(10).max(86_400),
  harvestStakingIntervalSecs: z.number().int().min(60).max(604_800),
  compoundShareholdersIntervalSecs: z.number().int().min(3600).max(604_800),
  compoundLpIntervalSecs: z.number().int().min(3600).max(604_800),
  checkpointBeforeExpiryIntervalSecs: z.number().int().min(3600).max(604_800),

  deadlineSecs: z.number().int().min(10).max(3_600),
  maxOffers: z.number().int().min(1).max(200),
  maxListings: z.number().int().min(1).max(100),
  maxExpireOffers: z.number().int().min(1).max(100),
  slippageBpsStaking: z.number().int().min(0).max(5_000),

  compoundSlippageBpsShareholders: z.number().int().min(0).max(5_000),
  compoundSlippageBpsLp: z.number().int().min(0).max(5_000),
  compoundMaxUsersShareholders: z.number().int().min(1).max(50),
  compoundMaxUsersLp: z.number().int().min(1).max(50),
  compoundLookaheadUsers: z.number().int().min(10).max(50_000),
  compoundScanChunkBlocks: z.number().int().min(1).max(100_000),
  compoundShareholdersStartBlock: z.number().int().nullable(),
  compoundLpStartBlock: z.number().int().nullable(),
  compoundMaxGas: z.number().int().min(100_000).max(25_000_000),
  compoundLpMinReward: z.bigint().min(0n),
  harvestStakingMinReward: z.bigint().min(0n),

  marketScanChunkBlocks: z.number().int().min(1).max(100_000),
  marketStartBlockOverride: z.number().int().nullable(),

  autoFurnaceBackoffEnabled: z.boolean(),
  autoFurnacePreflightEnabled: z.boolean(),
  autoFurnaceBackoffInitialMs: z.number().int().min(0),
  autoFurnaceBackoffMaxMs: z.number().int().min(0),
  autoFurnaceBackoffMultiplier: z.number().int().min(1).max(10),
  autoFurnaceBackoffJitterBps: z.number().int().min(0).max(5_000),

  listingsBackoffEnabled: z.boolean(),
  listingsPreflightEnabled: z.boolean(),
  listingsBackoffInitialMs: z.number().int().min(0),
  listingsBackoffMaxMs: z.number().int().min(0),
  listingsBackoffMultiplier: z.number().int().min(1).max(10),
  listingsBackoffJitterBps: z.number().int().min(0).max(5_000),
  listingsStartBlockOverride: z.number().int().nullable(),

  expireOffersBackoffEnabled: z.boolean(),
  expireOffersPreflightEnabled: z.boolean(),
  expireOffersBackoffInitialMs: z.number().int().min(0),
  expireOffersBackoffMaxMs: z.number().int().min(0),
  expireOffersBackoffMultiplier: z.number().int().min(1).max(10),
  expireOffersBackoffJitterBps: z.number().int().min(0).max(5_000),

  stateDir: z.string().min(1),
  deploymentStateDir: z.string().min(1),
  statusPath: z.string().min(1),
  marketStatePath: z.string().min(1),
  listingsStatePath: z.string().min(1),
  expireOffersStatePath: z.string().min(1),
  compoundShareholdersStatePath: z.string().min(1),
  compoundLpStatePath: z.string().min(1),
  checkpointBeforeExpiryStatePath: z.string().min(1),

  checkpointBeforeExpiryStartBlock: z.number().int().nullable().optional(),
  checkpointBeforeExpiryScanChunkBlocks: z.number().int().nullable().optional(),
  checkpointBeforeExpiryWindowSecs: z.number().int().nullable().optional(),
  checkpointBeforeExpiryMaxUsers: z.number().int().nullable().optional(),

  pokeStaleThresholdSecs: z.number().int().min(60).max(604_800),
  pokeLpTickIntervalSecs: z.number().int().min(60).max(86_400),
  pokeMinPendingEthDelta: z.string().min(1),
  pokeTakeoverScanChunkBlocks: z.number().int().min(1).max(100_000),
  pokeStatePath: z.string().min(1),

  automaxBonusIntervalSecs: z.number().int().min(3600).max(604_800),
  automaxBonusStatePath: z.string().min(1),
  automaxBonusStartBlock: z.number().int().nullable().optional(),
  automaxBonusScanChunkBlocks: z.number().int().nullable().optional(),
  automaxBonusMaxLocks: z.number().int().nullable().optional(),
  automaxBonusMinReward: z.string().min(1),

  settlementEnabled: z.boolean(),
  settlementPeriodSecs: z.number().int().min(3_600).max(604_800),
  settlementDayUtc: z.number().int().min(0).max(6),
  settlementHourUtc: z.number().int().min(0).max(23),
  settlementWindowDurationSecs: z.number().int().min(3_600).max(604_800),
  settlementTaskGapSecs: z.number().int().min(0).max(600),
  settlementRetryWindowSecs: z.number().int().min(60).max(86_400),
  settlementMaxDriftBps: z.number().int().min(1).max(5_000),
  settlementStatePath: z.string().min(1),

  compoundShareholderMinCadenceSecs: z.number().int().min(3_600).max(604_800),
  compoundShareholderSpreadSecs: z.number().int().min(0).max(86_400),
  compoundLpMinCadenceSecs: z.number().int().min(3_600).max(604_800),
  automaxOwnerCooldownSecs: z.number().int().min(3_600).max(604_800),

  subgraphUrl: z.string().url().nullable(),
  morningWindowHours: z.number().int().min(1).max(6),
  morningCachePath: z.string().min(1),

  lockPath: z.string().min(1),
  lockTtlMs: z.number().int().min(30_000),
  lockHeartbeatMs: z.number().int().min(5_000),
  hostLockName: z.string().min(1).max(106).nullable(),

  healthHost: z.string().min(1),
  healthPort: z.number().int().min(0).max(65_535),
  healthToken: z.string().min(1).nullable(),

  alertWebhookUrl: HttpUrl.nullable(),

  gasBalanceMinWei: z.bigint().min(0n).nullable(),
  gasBalanceCheckIntervalSecs: z.number().int().min(15).max(86_400),
  gasBalanceAlertRepeatSecs: z.number().int().min(60).max(604_800),
});

function resolveMaybeRelative(p: string | null | undefined): string | null | undefined {
  if (!p) return p;
  if (path.isAbsolute(p)) return p;
  return path.resolve(getKeeperRoot(), p);
}

function parseBigIntStrictEnv(
  v: unknown,
  envName: string,
  { defaultValue = 0n }: { defaultValue?: bigint } = {},
): bigint {
  if (v == null) return defaultValue;
  const s = String(v).trim();
  if (!s) return defaultValue;
  try {
    return BigInt(s);
  } catch {
    throw new Error(`Invalid bigint for ${envName}: ${s}`);
  }
}

function parseBigIntNullableEnv(v: unknown, envName: string): bigint | null {
  if (v == null) return null;
  const s = String(v).trim();
  if (!s) return null;
  try {
    return BigInt(s);
  } catch {
    throw new Error(`Invalid bigint for ${envName}: ${s}`);
  }
}

// C-3 (2026-04-17): strict int env that distinguishes "unset" (returns default)
// from "set but invalid" (throws at boot). The shared parseIntStrict silently
// returns the default for malformed values — so a typo in KEEPER_TX_MAX_FEE_GWEI
// would silently reset fee rails to the safe default instead of failing fast.
function parseIntStrictEnv(
  v: unknown,
  envName: string,
  { defaultValue }: { defaultValue: number },
): number {
  if (v == null) return defaultValue;
  const s = String(v).trim();
  if (!s) return defaultValue;
  if (!/^[+-]?\d+$/.test(s)) {
    throw new Error(`Invalid integer for ${envName}: ${s}`);
  }
  const n = Number.parseInt(s, 10);
  if (!Number.isFinite(n)) {
    throw new Error(`Invalid integer for ${envName}: ${s}`);
  }
  return n;
}

function assertFeeCapConsistency(cfg: {
  txMaxTotalFeeWei: bigint | null;
  txMaxFeePerGasWei: bigint | null;
}): void {
  if (cfg.txMaxTotalFeeWei != null && cfg.txMaxFeePerGasWei == null) {
    throw new Error(
      'KEEPER_TX_MAX_TOTAL_FEE_WEI is set but KEEPER_TX_MAX_FEE_GWEI is not. ' +
        'The total fee cap requires both to be effective.',
    );
  }
}

function gweiToWei(gwei: number | null | undefined): bigint | null {
  if (gwei == null) return null;
  const n = Number(gwei);
  if (!Number.isFinite(n) || n < 0) return null;
  return BigInt(Math.trunc(n)) * 1_000_000_000n;
}

// Parse a decimal ETH amount (e.g. "0.05") into wei exactly, without going
// through IEEE-754 float. Returns null for unset/empty; throws on malformed
// input so a typo in KEEPER_GAS_BALANCE_MIN_ETH fails fast at boot.
function etherStringToWei(v: unknown, envName: string): bigint | null {
  if (v == null) return null;
  const s = String(v).trim();
  if (!s) return null;
  if (!/^\d+(\.\d+)?$/.test(s)) {
    throw new Error(`Invalid decimal ETH amount for ${envName}: ${s}`);
  }
  const [whole, frac = ''] = s.split('.');
  if (frac.length > 18) {
    throw new Error(`Too many decimals for ${envName}: ${s} (max 18 = wei precision)`);
  }
  const fracPadded = frac.padEnd(18, '0');
  return BigInt(whole) * 1_000_000_000_000_000_000n + BigInt(fracPadded || '0');
}

const ALLOWED_DAEMON_TASKS: Set<string> = new Set([
  'poke',
  'harvest-staking',
  'sweep-market',
  'sweep-listings',
  'expire-offers',
  'compound-shareholders',
  'compound-lp',
  'checkpoint-before-expiry',
  'automax-bonus',
]);
const TASK_ALIASES: Record<string, string> = {
  harveststaking: 'harvest-staking',
  harvest_staking: 'harvest-staking',
  sweepmarket: 'sweep-market',
  sweep_market: 'sweep-market',
  market: 'sweep-market',

  sweeplistings: 'sweep-listings',
  sweep_listings: 'sweep-listings',
  listings: 'sweep-listings',

  expireoffers: 'expire-offers',
  expire_offers: 'expire-offers',
  expire: 'expire-offers',

  compoundshareholders: 'compound-shareholders',
  compound_shareholders: 'compound-shareholders',
  compoundbarons: 'compound-shareholders',
  compound_barons: 'compound-shareholders',
  barons: 'compound-shareholders',

  compoundlp: 'compound-lp',
  compound_lp: 'compound-lp',
  lp: 'compound-lp',

  checkpointbeforeexpiry: 'checkpoint-before-expiry',
  checkpoint_before_expiry: 'checkpoint-before-expiry',
  'checkpoint-expiry': 'checkpoint-before-expiry',

  automaxbonus: 'automax-bonus',
  automax_bonus: 'automax-bonus',
  automax: 'automax-bonus',
};

function parseDaemonTasks(raw: unknown): string[] {
  const s = String(raw ?? '').trim();
  if (!s) return ['poke'];

  // Accept whitespace, comma, OR semicolon as a delimiter. This mirrors
  // `parseHostHintEnv` and prevents silent "one giant token" typos like
  // `KEEPER_DAEMON_TASKS=poke;sweep-market` from being rejected at startup
  // with a confusing error like "Unknown task: poke;sweep-market".
  const parts = s
    .split(/[\s,;]+/)
    .map((x) => x.trim())
    .filter(Boolean);

  const out: string[] = [];
  for (const p0 of parts) {
    const p = p0.toLowerCase();
    if (p === 'all' || p === '*') {
      return [
        'poke',
        'harvest-staking',
        'sweep-market',
        'sweep-listings',
        'expire-offers',
        'compound-shareholders',
        'compound-lp',
        'checkpoint-before-expiry',
        'automax-bonus',
      ];
    }

    const normalized = TASK_ALIASES[p] ?? p;
    if (!ALLOWED_DAEMON_TASKS.has(normalized)) {
      throw new Error(
        `Unknown task in KEEPER_DAEMON_TASKS: ${p0}. Expected one of: poke, harvest-staking, sweep-market, sweep-listings, expire-offers, compound-shareholders, compound-lp, checkpoint-before-expiry, automax-bonus, all`,
      );
    }

    if (!out.includes(normalized)) out.push(normalized);
  }

  return out.length ? out : ['poke'];
}

/// Hard-forbid the `allowUnsafeMinOut` / `allowUnsafeMinVeOut` overrides under live runs.
/// These flags are local-development helpers that submit swaps with `minClaimOut = 0` /
/// `minVeOut = 0` after the keeper's own slippage check fails. Both surfaces are
/// MEV-sandwich foot-guns in production, so the gate fails closed: a misconfigured
/// live deployment cannot accidentally submit unprotected transactions.
export function assertNoLiveUnsafeMinOut(input: {
  liveRun: boolean;
  allowUnsafeMinOut: boolean;
  allowUnsafeMinVeOut: boolean;
}): void {
  if (!input.liveRun) return;
  if (input.allowUnsafeMinOut) {
    throw new Error(
      'KEEPER_ALLOW_UNSAFE_MIN_OUT=1 is forbidden under KEEPER_LIVE_RUN=1. ' +
        'This flag forces minClaimOut=0 on harvest swaps, which is MEV-exploitable in production.',
    );
  }
  if (input.allowUnsafeMinVeOut) {
    throw new Error(
      'KEEPER_ALLOW_UNSAFE_MIN_VE_OUT=1 is forbidden under KEEPER_LIVE_RUN=1. ' +
        'This flag forces minVeOut=0 on auto-compound, which is MEV-exploitable in production.',
    );
  }
}

export const MAX_LIVE_DEADLINE_SECS = 60;

/// Hard-forbid wide swap / market execution deadlines under live runs.
/// Wide deadlines leave keeper-submitted transactions valid across many blocks,
/// which turns otherwise tight min-out checks into stale standing orders.
export function assertLiveDeadlineBound(input: { liveRun: boolean; deadlineSecs: number }): void {
  if (!input.liveRun) return;
  if (input.deadlineSecs > MAX_LIVE_DEADLINE_SECS) {
    throw new Error(
      `KEEPER_DEADLINE_SECS must be <= ${MAX_LIVE_DEADLINE_SECS} under KEEPER_LIVE_RUN=1. ` +
        'Wide live deadlines leave keeper transactions exposed to stale execution and MEV.',
    );
  }
}

export function loadConfigFromEnv(): KeeperConfig {
  const deployment = assertSafeDeploymentName(process.env.KEEPER_DEPLOYMENT);

  const privateRpcUrl = process.env.KEEPER_PRIVATE_RPC_URL;
  const publicRpcUrl = process.env.KEEPER_PUBLIC_RPC_URL ?? privateRpcUrl;

  // Cross-check: the configured RPC hostname must match the deployment's chain.
  // Catches the failure mode where a staging (base_sepolia) keeper env is
  // copied from a mainnet file and accidentally keeps a mainnet Alchemy URL,
  // or vice versa.
  assertDeploymentRpcConsistency(deployment, [
    { name: 'KEEPER_PUBLIC_RPC_URL', url: publicRpcUrl },
    { name: 'KEEPER_PRIVATE_RPC_URL', url: privateRpcUrl },
  ]);

  const normalizeToken = (v: unknown): string | null => {
    if (v == null) return null;
    const s = String(v).trim();
    return s ? s : null;
  };

  // Backward compatible:
  // - KEEPER_RPC_AUTH_TOKEN applies to BOTH public + private RPCs.
  // - Use the more specific vars to avoid leaking private proxy tokens to a public upstream.
  const sharedRpcAuthToken = normalizeToken(process.env.KEEPER_RPC_AUTH_TOKEN);
  const publicRpcAuthToken =
    normalizeToken(process.env.KEEPER_PUBLIC_RPC_AUTH_TOKEN) ?? sharedRpcAuthToken;
  const privateRpcAuthToken =
    normalizeToken(process.env.KEEPER_PRIVATE_RPC_AUTH_TOKEN) ?? sharedRpcAuthToken;

  // RPC transport tuning. Avoid indefinite hangs on degraded endpoints.
  // Defaults are conservative; increase if your RPC provider is slow for eth_getLogs.
  const rpcTimeoutMs = clamp(
    parseIntStrict(process.env.KEEPER_RPC_TIMEOUT_MS, { defaultValue: 15_000 }) ?? 15_000,
    { min: 250, max: 120_000 },
  );

  const publicRpcTimeoutMs = clamp(
    parseIntStrict(process.env.KEEPER_PUBLIC_RPC_TIMEOUT_MS, { defaultValue: rpcTimeoutMs }) ??
      rpcTimeoutMs,
    { min: 250, max: 120_000 },
  );

  const privateRpcTimeoutMs = clamp(
    parseIntStrict(process.env.KEEPER_PRIVATE_RPC_TIMEOUT_MS, { defaultValue: rpcTimeoutMs }) ??
      rpcTimeoutMs,
    { min: 250, max: 120_000 },
  );

  const rpcRetryCount = clamp(
    parseIntStrict(process.env.KEEPER_RPC_RETRY_COUNT, { defaultValue: 0 }) ?? 0,
    { min: 0, max: 10 },
  );

  const rpcBatchWaitMs = clamp(
    parseIntStrict(process.env.KEEPER_RPC_BATCH_WAIT_MS, { defaultValue: 0 }) ?? 0,
    { min: 0, max: 1_000 },
  );

  // Multicall3 address.  Defaults to the canonical CREATE2 address used on
  // every mainstream chain; can be overridden for custom testnets or chains
  // where Multicall3 was redeployed at a non-canonical address.
  const multicall3AddressRaw = String(process.env.KEEPER_MULTICALL3_ADDRESS ?? '').trim();
  const multicall3Address = multicall3AddressRaw.length > 0 ? multicall3AddressRaw : null;
  const multicall3BlockCreated = parseIntStrict(process.env.KEEPER_MULTICALL3_BLOCK_CREATED, {
    defaultValue: null,
  });

  // Event-driven (WebSocket) subscriptions for hot tasks (phase 4).
  const wsUrlRaw = String(process.env.KEEPER_WS_URL ?? '').trim();
  const wsUrl = wsUrlRaw || null;
  const wsUrlFallbackRaw = String(process.env.KEEPER_WS_URL_FALLBACK ?? '').trim();
  const wsUrlFallback = wsUrlFallbackRaw || null;

  // Both default to the full hot-task set.  Empty string is treated as an
  // explicit kill-switch: `KEEPER_EVENT_DRIVEN_TASKS=""` disables every
  // event-driven trigger and leaves the polling scheduler as the sole
  // task driver — useful during incident response.
  const eventDrivenTasksRaw = process.env.KEEPER_EVENT_DRIVEN_TASKS;
  const EVENT_DRIVEN_TASK_DEFAULTS = ['poke', 'sweep-market', 'sweep-listings', 'expire-offers'];
  let eventDrivenTasks: string[];
  if (eventDrivenTasksRaw == null) {
    eventDrivenTasks = [...EVENT_DRIVEN_TASK_DEFAULTS];
  } else if (eventDrivenTasksRaw.trim() === '') {
    eventDrivenTasks = [];
  } else {
    eventDrivenTasks = eventDrivenTasksRaw
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
      .filter((name) => EVENT_DRIVEN_TASK_DEFAULTS.includes(name));
  }

  const safetyNetIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_SAFETY_NET_INTERVAL_SECS, { defaultValue: 3_600 }) ?? 3_600,
    { min: 60, max: 86_400 },
  );

  const wsDisconnectedGraceSecs = clamp(
    parseIntStrict(process.env.KEEPER_WS_DISCONNECTED_GRACE_SECS, { defaultValue: 300 }) ?? 300,
    { min: 0, max: 3_600 },
  );

  const eventMinRepeatSecs = clamp(
    parseIntStrict(process.env.KEEPER_EVENT_MIN_REPEAT_SECS, { defaultValue: 5 }) ?? 5,
    { min: 0, max: 3_600 },
  );

  // Same Sepolia/mainnet cross-wiring guard as the HTTP URLs — a WSS
  // misroute would silently deliver events for the wrong chain into the
  // keeper's event bus, which is far worse than getting a bad read.
  assertDeploymentRpcConsistency(deployment, [
    { name: 'KEEPER_WS_URL', url: wsUrl ?? undefined },
    { name: 'KEEPER_WS_URL_FALLBACK', url: wsUrlFallback ?? undefined },
  ]);

  const privateKey = process.env.KEEPER_PRIVATE_KEY;

  // Optional safety rail: refuse to run unless the configured private key
  // corresponds to this expected address.
  // Useful to prevent accidental live runs with the wrong key.
  const expectedAccountAddressRaw =
    process.env.KEEPER_EXPECTED_ADDRESS ?? process.env.KEEPER_EXPECTED_ACCOUNT_ADDRESS ?? null;
  const expectedAccountAddress =
    expectedAccountAddressRaw != null && String(expectedAccountAddressRaw).trim()
      ? String(expectedAccountAddressRaw).trim()
      : null;

  // SAFE DEFAULT: dry-run unless explicitly disabled.
  const dryRun = parseBool(process.env.KEEPER_DRY_RUN, { defaultValue: true });
  const liveRun = parseBool(process.env.KEEPER_LIVE_RUN, { defaultValue: false });

  // Refuse to run in live mode unless explicitly acknowledged.
  if (!dryRun && !liveRun) {
    throw new Error(
      'Refusing to run with KEEPER_DRY_RUN=0 unless KEEPER_LIVE_RUN=1 is also set. ' +
        'This is a safety rail to prevent accidental live transaction submission.',
    );
  }

  const allowUnsafeMinOut = parseBool(process.env.KEEPER_ALLOW_UNSAFE_MIN_OUT, {
    defaultValue: false,
  });
  const allowUnsafeMinVeOut = parseBool(process.env.KEEPER_ALLOW_UNSAFE_MIN_VE_OUT, {
    defaultValue: false,
  });

  assertNoLiveUnsafeMinOut({ liveRun, allowUnsafeMinOut, allowUnsafeMinVeOut });

  // Safety pause toggles.
  const paused = parseBool(process.env.KEEPER_PAUSED, { defaultValue: false });

  // Transaction safety rails.
  const txConfirmations = clamp(
    parseIntStrict(process.env.KEEPER_TX_CONFIRMATIONS, { defaultValue: 2 }) ?? 2,
    { min: 1, max: 100 },
  );

  const txReceiptTimeoutSecs = clamp(
    parseIntStrict(process.env.KEEPER_TX_RECEIPT_TIMEOUT_SECS, { defaultValue: 600 }) ?? 600,
    { min: 5, max: 3_600 },
  );
  const txReceiptTimeoutMs = txReceiptTimeoutSecs * 1000;

  // Fee caps (EIP-1559). Base L2 gas is typically <0.1 gwei; 10 gwei provides
  // a ~100x safety margin while catching accidental mainnet-level fee spikes.
  // C-3 (2026-04-17): use parseIntStrictEnv so that a malformed env (e.g.
  // KEEPER_TX_MAX_FEE_GWEI=abc) throws at boot instead of silently applying
  // the default.
  const txMaxFeePerGasWei = gweiToWei(
    parseIntStrictEnv(process.env.KEEPER_TX_MAX_FEE_GWEI, 'KEEPER_TX_MAX_FEE_GWEI', {
      defaultValue: 10,
    }),
  );
  let txMaxPriorityFeePerGasWei = gweiToWei(
    parseIntStrictEnv(
      process.env.KEEPER_TX_MAX_PRIORITY_FEE_GWEI,
      'KEEPER_TX_MAX_PRIORITY_FEE_GWEI',
      { defaultValue: 1 },
    ),
  );

  // For sub-Gwei precision on L2s, allow an exact wei override.
  const priorityFeeWeiOverride = process.env.KEEPER_TX_MAX_PRIORITY_FEE_WEI?.trim();
  if (priorityFeeWeiOverride) {
    txMaxPriorityFeePerGasWei = parseBigIntStrictEnv(
      priorityFeeWeiOverride,
      'KEEPER_TX_MAX_PRIORITY_FEE_WEI',
    );
  }

  if (txMaxFeePerGasWei != null && txMaxFeePerGasWei <= 0n) {
    throw new Error(
      'Invalid fee cap: KEEPER_TX_MAX_FEE_GWEI resolves to 0 wei. ' +
        'This would silently skip all transactions. Unset or use a positive value.',
    );
  }

  if (
    txMaxFeePerGasWei != null &&
    txMaxPriorityFeePerGasWei != null &&
    txMaxPriorityFeePerGasWei > txMaxFeePerGasWei
  ) {
    throw new Error(
      'Invalid fee caps: KEEPER_TX_MAX_PRIORITY_FEE_GWEI must be <= KEEPER_TX_MAX_FEE_GWEI',
    );
  }

  // Optional total fee cap (worst case): gasLimit * maxFeePerGas.
  // Set to empty/unset to disable.
  const txMaxTotalFeeWei = parseBigIntNullableEnv(
    process.env.KEEPER_TX_MAX_TOTAL_FEE_WEI,
    'KEEPER_TX_MAX_TOTAL_FEE_WEI',
  );

  assertFeeCapConsistency({ txMaxTotalFeeWei, txMaxFeePerGasWei });

  const txGasLimitMultiplierBps = clamp(
    parseIntStrict(process.env.KEEPER_TX_GAS_LIMIT_MULTIPLIER_BPS, { defaultValue: 12_000 }) ??
      12_000,
    { min: 10_000, max: 30_000 },
  );

  // Optional maximum gas limit per tx (gas units).
  // Safe default: 25,000,000 (fits 50-user compound batches on Base L2's 30M block limit).
  // Set to empty to disable.
  const txMaxGasLimit =
    process.env.KEEPER_TX_MAX_GAS_LIMIT == null
      ? 25_000_000n
      : parseBigIntNullableEnv(process.env.KEEPER_TX_MAX_GAS_LIMIT, 'KEEPER_TX_MAX_GAS_LIMIT');

  const allowTxWhilePending = parseBool(process.env.KEEPER_ALLOW_TX_WHILE_PENDING, {
    defaultValue: false,
  });

  // Backwards-compatible default cadence.
  const intervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_INTERVAL_SECS, { defaultValue: 300 }) ?? 300,
    {
      min: 10,
      max: 86_400,
    },
  );

  // Adaptive cadence: two separate intervals, picked at scheduling time based
  // on the tier observed on the keeper's RPC proxy.  Both default to
  // `intervalSecs` (and a sane floor for the fallback case) so deployments
  // that haven't opted in keep today's behaviour.
  const intervalSecsPrimary = clamp(
    parseIntStrict(process.env.KEEPER_INTERVAL_SECS_PRIMARY, { defaultValue: intervalSecs }) ??
      intervalSecs,
    { min: 10, max: 86_400 },
  );
  // Fallback cadence defaults to max(primary, 1800) — we never go *faster*
  // than primary when on fallback, and the 30-minute floor matches what we
  // already ship on staging via KEEPER_INTERVAL_SECS=1800.
  const intervalSecsFallbackDefault = Math.max(intervalSecsPrimary, 1_800);
  const intervalSecsFallback = clamp(
    parseIntStrict(process.env.KEEPER_INTERVAL_SECS_FALLBACK, {
      defaultValue: intervalSecsFallbackDefault,
    }) ?? intervalSecsFallbackDefault,
    { min: 10, max: 86_400 },
  );

  // Multi-task daemon config
  const daemonTasks = parseDaemonTasks(process.env.KEEPER_DAEMON_TASKS ?? 'poke');

  const daemonJitterBps = clamp(
    parseIntStrict(process.env.KEEPER_DAEMON_JITTER_BPS, { defaultValue: 500 }) ?? 500,
    {
      min: 0,
      max: 5_000,
    },
  );

  const daemonLockWaitSecs = clamp(
    parseIntStrict(process.env.KEEPER_DAEMON_LOCK_WAIT_SECS, { defaultValue: 30 }) ?? 30,
    { min: 0, max: 3_600 },
  );

  const pokeIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_POKE_INTERVAL_SECS, { defaultValue: intervalSecs }) ??
      intervalSecs,
    { min: 10, max: 86_400 },
  );

  const sweepMarketIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_SWEEP_MARKET_INTERVAL_SECS, { defaultValue: intervalSecs }) ??
      intervalSecs,
    { min: 10, max: 86_400 },
  );

  const sweepListingsIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_SWEEP_LISTINGS_INTERVAL_SECS, {
      defaultValue: intervalSecs,
    }) ?? intervalSecs,
    { min: 10, max: 86_400 },
  );

  const expireOffersIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_EXPIRE_OFFERS_INTERVAL_SECS, {
      defaultValue: intervalSecs,
    }) ?? intervalSecs,
    { min: 10, max: 86_400 },
  );

  const harvestStakingIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_HARVEST_STAKING_INTERVAL_SECS, { defaultValue: 900 }) ?? 900,
    { min: 60, max: 604_800 },
  );

  const compoundShareholdersIntervalSecs = clamp(
    parseIntStrict(
      process.env.KEEPER_COMPOUND_SHAREHOLDER_INTERVAL_SECS ??
        process.env.KEEPER_COMPOUND_SHAREHOLDERS_INTERVAL_SECS,
      { defaultValue: 7_200 },
    ) ?? 7_200,
    { min: 3600, max: 604_800 },
  );

  const compoundLpIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_LP_INTERVAL_SECS, { defaultValue: 7_200 }) ?? 7_200,
    { min: 3600, max: 604_800 },
  );

  const checkpointBeforeExpiryIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_CHECKPOINT_BEFORE_EXPIRY_INTERVAL_SECS, {
      defaultValue: 21_600,
    }) ?? 21_600,
    { min: 3600, max: 604_800 },
  );

  const pokeStaleThresholdSecs = clamp(
    parseIntStrict(process.env.KEEPER_POKE_STALE_SECS, { defaultValue: 86_400 }) ?? 86_400,
    { min: 60, max: 604_800 },
  );

  const pokeLpTickIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_POKE_LP_TICK_INTERVAL_SECS, { defaultValue: 3600 }) ?? 3600,
    { min: 60, max: 86_400 },
  );

  // Minimum pendingShareholderETH delta (in wei) before triggering a poke.
  // Default 0.01 ETH. Takeovers already flush on-chain via onTakeover(), so
  // this only catches failed flushes. Rounding dust (~5000 wei) is never
  // worth a poke tx.
  const pokeMinPendingEthDelta =
    process.env.KEEPER_POKE_MIN_PENDING_ETH_DELTA || '10000000000000000';

  // Default chunk size mirrors the market scan: if the operator already tuned
  // *_SCAN_CHUNK_BLOCKS for a strict provider we follow suit automatically.
  // 2000 was the historical market-scan default and is a sane upstream-friendly
  // value when no scan chunks have been tuned.
  const pokeTakeoverScanChunkBlocks = clamp(
    parseIntStrict(process.env.KEEPER_POKE_TAKEOVER_SCAN_CHUNK_BLOCKS, {
      defaultValue: null,
    }) ??
      parseIntStrict(process.env.KEEPER_MARKET_SCAN_CHUNK_BLOCKS, {
        defaultValue: 2000,
      }) ??
      2000,
    { min: 1, max: 100_000 },
  );

  const automaxBonusIntervalSecs = clamp(
    parseIntStrict(process.env.KEEPER_AUTOMAX_BONUS_INTERVAL_SECS ?? '7200', {
      defaultValue: 7_200,
    }) ?? 7_200,
    { min: 3600, max: 604_800 },
  );

  // Optional tuning for checkpoint-before-expiry scanning + selection
  const checkpointBeforeExpiryStartBlockRaw = parseIntStrict(
    process.env.KEEPER_CHECKPOINT_BEFORE_EXPIRY_START_BLOCK,
    { defaultValue: null },
  );
  const checkpointBeforeExpiryStartBlock =
    checkpointBeforeExpiryStartBlockRaw != null && checkpointBeforeExpiryStartBlockRaw >= 0
      ? checkpointBeforeExpiryStartBlockRaw
      : null;

  const checkpointBeforeExpiryScanChunkBlocksRaw = parseIntStrict(
    process.env.KEEPER_CHECKPOINT_BEFORE_EXPIRY_SCAN_CHUNK_BLOCKS,
    { defaultValue: null },
  );
  const checkpointBeforeExpiryScanChunkBlocks =
    checkpointBeforeExpiryScanChunkBlocksRaw != null && checkpointBeforeExpiryScanChunkBlocksRaw > 0
      ? clamp(checkpointBeforeExpiryScanChunkBlocksRaw, { min: 1, max: 100_000 })
      : null;

  const checkpointBeforeExpiryWindowSecsRaw = parseIntStrict(
    process.env.KEEPER_CHECKPOINT_BEFORE_EXPIRY_WINDOW_SECS,
    { defaultValue: null },
  );
  const checkpointBeforeExpiryWindowSecs =
    checkpointBeforeExpiryWindowSecsRaw != null && checkpointBeforeExpiryWindowSecsRaw > 0
      ? clamp(checkpointBeforeExpiryWindowSecsRaw, { min: 3600, max: 604_800 })
      : null;

  const checkpointBeforeExpiryMaxUsersRaw = parseIntStrict(
    process.env.KEEPER_CHECKPOINT_BEFORE_EXPIRY_MAX_USERS,
    { defaultValue: null },
  );
  const checkpointBeforeExpiryMaxUsers =
    checkpointBeforeExpiryMaxUsersRaw != null && checkpointBeforeExpiryMaxUsersRaw > 0
      ? clamp(checkpointBeforeExpiryMaxUsersRaw, { min: 1, max: 1000 })
      : null;

  const automaxBonusStartBlock = process.env.KEEPER_AUTOMAX_BONUS_START_BLOCK
    ? parseIntStrict(process.env.KEEPER_AUTOMAX_BONUS_START_BLOCK, { defaultValue: null })
    : null;

  const automaxBonusScanChunkBlocks = process.env.KEEPER_AUTOMAX_BONUS_SCAN_CHUNK_BLOCKS
    ? clamp(
        parseIntStrict(process.env.KEEPER_AUTOMAX_BONUS_SCAN_CHUNK_BLOCKS, {
          defaultValue: 10_000,
        }) ?? 10_000,
        { min: 1, max: 100_000 },
      )
    : null;

  const automaxBonusMaxLocks = process.env.KEEPER_AUTOMAX_BONUS_MAX_LOCKS
    ? clamp(
        parseIntStrict(process.env.KEEPER_AUTOMAX_BONUS_MAX_LOCKS, { defaultValue: 50 }) ?? 50,
        { min: 1, max: 500 },
      )
    : null;

  // Minimum bonus CLAIM (in wei) for an autoMax lock to be worth claiming.
  // Locks below this threshold are skipped until their bonus grows large enough.
  // Default 100 CLAIM (100e18 wei).
  const automaxBonusMinReward =
    process.env.KEEPER_AUTOMAX_BONUS_MIN_REWARD || '100000000000000000000';

  // -- Settlement window (opt-in; configurable cadence) --

  const settlementEnabled = parseBool(process.env.KEEPER_SETTLEMENT_ENABLED, {
    defaultValue: false,
  });

  // Master cadence knob. 86400 = daily (default), 604800 = weekly.
  const settlementPeriodSecs = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_PERIOD_SECS, { defaultValue: 86_400 }) ?? 86_400,
    { min: 3_600, max: 604_800 },
  );

  // Day-of-week anchor. Only consulted when the period is a whole number of
  // weeks (e.g. weekly); ignored for sub-week periods like daily.
  const settlementDayUtc = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_DAY_UTC, { defaultValue: 4 }) ?? 4,
    { min: 0, max: 6 },
  );

  const settlementHourUtc = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_HOUR_UTC, { defaultValue: 0 }) ?? 0,
    { min: 0, max: 23 },
  );

  // A window may not outlast its own cycle, else consecutive windows overlap.
  const settlementWindowDurationSecs = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_WINDOW_DURATION_SECS, { defaultValue: 86_400 }) ??
      86_400,
    { min: 3_600, max: settlementPeriodSecs },
  );

  const settlementTaskGapSecs = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_TASK_GAP_SECS, { defaultValue: 60 }) ?? 60,
    { min: 0, max: 600 },
  );

  const settlementRetryWindowSecs = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_RETRY_WINDOW_SECS, { defaultValue: 3_600 }) ??
      3_600,
    { min: 60, max: 86_400 },
  );

  const settlementMaxDriftBps = clamp(
    parseIntStrict(process.env.KEEPER_SETTLEMENT_MAX_DRIFT_BPS, { defaultValue: 100 }) ?? 100,
    { min: 1, max: 5_000 },
  );

  // Per-user floors. Each defaults to the master settlement period so flipping
  // KEEPER_SETTLEMENT_PERIOD_SECS moves the whole system together; set an
  // override to decouple a single task.
  const compoundShareholderMinCadenceSecs = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_SHAREHOLDER_MIN_CADENCE_SECS, {
      defaultValue: settlementPeriodSecs,
    }) ?? settlementPeriodSecs,
    { min: 3_600, max: 604_800 },
  );

  // Intra-day spread for compound-shareholders. 0 = no spread (eligible users
  // batch together). A positive value fans synchronized users across the window
  // with deterministic per-user jitter; effective cadence becomes
  // [floor, floor + spread). Clamped to one day.
  const compoundShareholderSpreadSecs = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_SHAREHOLDER_SPREAD_SECS, { defaultValue: 0 }) ?? 0,
    { min: 0, max: 86_400 },
  );

  const compoundLpMinCadenceSecs = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_LP_MIN_CADENCE_SECS, {
      defaultValue: settlementPeriodSecs,
    }) ?? settlementPeriodSecs,
    { min: 3_600, max: 604_800 },
  );

  const automaxOwnerCooldownSecs = clamp(
    parseIntStrict(process.env.KEEPER_AUTOMAX_OWNER_COOLDOWN_SECS, {
      defaultValue: settlementPeriodSecs,
    }) ?? settlementPeriodSecs,
    { min: 3_600, max: 604_800 },
  );

  const subgraphUrl = process.env.KEEPER_SUBGRAPH_URL?.trim() || null;

  const morningWindowHours = clamp(
    parseIntStrict(process.env.KEEPER_MORNING_WINDOW_HOURS, { defaultValue: 1 }) ?? 1,
    { min: 1, max: 6 },
  );

  const defaultDeadlineSecs = liveRun ? MAX_LIVE_DEADLINE_SECS : 120;
  const deadlineSecs = clamp(
    parseIntStrict(process.env.KEEPER_DEADLINE_SECS, { defaultValue: defaultDeadlineSecs }) ??
      defaultDeadlineSecs,
    {
      min: 10,
      max: 3_600,
    },
  );
  assertLiveDeadlineBound({ liveRun, deadlineSecs });

  const maxOffers = clamp(
    parseIntStrict(process.env.KEEPER_MAX_OFFERS, { defaultValue: 50 }) ?? 50,
    {
      min: 1,
      max: 100,
    },
  );

  const maxListings = clamp(
    parseIntStrict(process.env.KEEPER_MAX_LISTINGS, { defaultValue: 25 }) ?? 25,
    {
      min: 1,
      max: 100,
    },
  );

  const maxExpireOffers = clamp(
    parseIntStrict(process.env.KEEPER_MAX_EXPIRE_OFFERS, { defaultValue: 25 }) ?? 25,
    {
      min: 1,
      max: 100,
    },
  );

  const slippageBpsStaking = clamp(
    parseIntStrict(process.env.KEEPER_SLIPPAGE_BPS_STAKING, { defaultValue: 100 }) ?? 100,
    { min: 0, max: 5_000 },
  );

  const compoundSlippageBpsShareholders = clamp(
    parseIntStrict(
      process.env.KEEPER_COMPOUND_SHAREHOLDER_SLIPPAGE_BPS ??
        process.env.KEEPER_COMPOUND_SHAREHOLDERS_SLIPPAGE_BPS,
      { defaultValue: 200 },
    ) ?? 200,
    { min: 0, max: 5_000 },
  );

  const compoundSlippageBpsLp = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_LP_SLIPPAGE_BPS, { defaultValue: 100 }) ?? 100,
    { min: 0, max: 5_000 },
  );

  const compoundMaxUsersShareholders = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_SHAREHOLDER_MAX_USERS, { defaultValue: 25 }) ?? 25,
    { min: 1, max: 50 },
  );

  const compoundMaxUsersLp = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_LP_MAX_USERS, { defaultValue: 25 }) ?? 25,
    { min: 1, max: 50 },
  );

  const compoundLookaheadUsers = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_LOOKAHEAD_USERS, { defaultValue: 200 }) ?? 200,
    { min: 10, max: 50_000 },
  );

  const compoundScanChunkBlocks = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_SCAN_CHUNK_BLOCKS, { defaultValue: 5000 }) ?? 5000,
    { min: 1, max: 100_000 },
  );

  const compoundMaxGas = clamp(
    parseIntStrict(process.env.KEEPER_COMPOUND_MAX_GAS, { defaultValue: 15_000_000 }) ?? 15_000_000,
    { min: 100_000, max: 25_000_000 },
  );

  // Optional overrides if your deployments manifest has startBlock=0
  const compoundShareholdersStartBlock = parseIntStrict(
    process.env.KEEPER_COMPOUND_SHAREHOLDER_START_BLOCK,
    { defaultValue: null },
  );
  const compoundLpStartBlock = parseIntStrict(process.env.KEEPER_COMPOUND_LP_START_BLOCK, {
    defaultValue: null,
  });

  const compoundLpMinReward = parseBigIntStrictEnv(
    process.env.KEEPER_COMPOUND_LP_MIN_REWARD,
    'KEEPER_COMPOUND_LP_MIN_REWARD',
    {
      defaultValue: 1000000000000000000000n, // 1000 CLAIM
    },
  );

  const harvestStakingMinReward = parseBigIntStrictEnv(
    process.env.KEEPER_HARVEST_STAKING_MIN_REWARD,
    'KEEPER_HARVEST_STAKING_MIN_REWARD',
    {
      defaultValue: 1000000000000000000000n, // 1000 CLAIM
    },
  );

  const marketScanChunkBlocks = clamp(
    parseIntStrict(process.env.KEEPER_MARKET_SCAN_CHUNK_BLOCKS, { defaultValue: 2000 }) ?? 2000,
    { min: 1, max: 100_000 },
  );

  const marketStartBlockOverride = parseIntStrict(process.env.KEEPER_MARKET_START_BLOCK, {
    defaultValue: null,
  });

  // Market auto-furnace backoff (production safety)
  const autoFurnaceBackoffEnabled = parseBool(process.env.KEEPER_AUTO_FURNACE_BACKOFF_ENABLED, {
    defaultValue: true,
  });

  // Market auto-furnace preflight
  // If enabled, we simulate `executeAutoFurnace(offerId)` via eth_call before broadcasting.
  // This avoids wasting gas on deterministic reverts (ex: bonus target not met yet).
  const autoFurnacePreflightEnabled = parseBool(process.env.KEEPER_AUTO_FURNACE_PREFLIGHT_ENABLED, {
    defaultValue: true,
  });

  const autoFurnaceBackoffInitialSecs = clamp(
    parseIntStrict(process.env.KEEPER_AUTO_FURNACE_BACKOFF_INITIAL_SECS, { defaultValue: 300 }) ??
      300,
    { min: 10, max: 86_400 },
  );

  const autoFurnaceBackoffMaxSecs = clamp(
    parseIntStrict(process.env.KEEPER_AUTO_FURNACE_BACKOFF_MAX_SECS, { defaultValue: 86_400 }) ??
      86_400,
    { min: 60, max: 604_800 },
  );

  const autoFurnaceBackoffMultiplier = clamp(
    parseIntStrict(process.env.KEEPER_AUTO_FURNACE_BACKOFF_MULTIPLIER, { defaultValue: 3 }) ?? 3,
    { min: 1, max: 10 },
  );

  const autoFurnaceBackoffJitterBps = clamp(
    parseIntStrict(process.env.KEEPER_AUTO_FURNACE_BACKOFF_JITTER_BPS, { defaultValue: 500 }) ??
      500,
    { min: 0, max: 5_000 },
  );

  const autoFurnaceBackoffInitialMs = autoFurnaceBackoffInitialSecs * 1000;
  const autoFurnaceBackoffMaxMs = Math.max(
    autoFurnaceBackoffInitialMs,
    autoFurnaceBackoffMaxSecs * 1000,
  );

  // Listing settlement backoff (production safety)
  const listingsBackoffEnabled = parseBool(process.env.KEEPER_LISTINGS_BACKOFF_ENABLED, {
    defaultValue: true,
  });

  // Listing settlement preflight
  // If enabled, we simulate `sellListedLockToFurnace(tokenId)` via eth_call before broadcasting.
  // This avoids wasting gas on deterministic reverts (ex: quote < minClaimOut).
  const listingsPreflightEnabled = parseBool(process.env.KEEPER_LISTINGS_PREFLIGHT_ENABLED, {
    defaultValue: true,
  });

  const listingsBackoffInitialSecs = clamp(
    parseIntStrict(process.env.KEEPER_LISTINGS_BACKOFF_INITIAL_SECS, { defaultValue: 300 }) ?? 300,
    { min: 10, max: 86_400 },
  );

  const listingsBackoffMaxSecs = clamp(
    parseIntStrict(process.env.KEEPER_LISTINGS_BACKOFF_MAX_SECS, { defaultValue: 86_400 }) ??
      86_400,
    { min: 60, max: 604_800 },
  );

  const listingsBackoffMultiplier = clamp(
    parseIntStrict(process.env.KEEPER_LISTINGS_BACKOFF_MULTIPLIER, { defaultValue: 3 }) ?? 3,
    { min: 1, max: 10 },
  );

  const listingsBackoffJitterBps = clamp(
    parseIntStrict(process.env.KEEPER_LISTINGS_BACKOFF_JITTER_BPS, { defaultValue: 500 }) ?? 500,
    { min: 0, max: 5_000 },
  );

  const listingsBackoffInitialMs = listingsBackoffInitialSecs * 1000;
  const listingsBackoffMaxMs = Math.max(listingsBackoffInitialMs, listingsBackoffMaxSecs * 1000);

  // Optional override for listings start block
  const listingsStartBlockOverride = parseIntStrict(process.env.KEEPER_LISTINGS_START_BLOCK, {
    defaultValue: null,
  });

  // Expire offers backoff (production safety)
  const expireOffersBackoffEnabled = parseBool(process.env.KEEPER_EXPIRE_OFFERS_BACKOFF_ENABLED, {
    defaultValue: true,
  });

  // Expire offers preflight
  // If enabled, we simulate `cancelExpiredBonusTargetEscrow(offerId)` via eth_call before broadcasting.
  const expireOffersPreflightEnabled = parseBool(
    process.env.KEEPER_EXPIRE_OFFERS_PREFLIGHT_ENABLED,
    { defaultValue: true },
  );

  const expireOffersBackoffInitialSecs = clamp(
    parseIntStrict(process.env.KEEPER_EXPIRE_OFFERS_BACKOFF_INITIAL_SECS, { defaultValue: 300 }) ??
      300,
    { min: 10, max: 86_400 },
  );

  const expireOffersBackoffMaxSecs = clamp(
    parseIntStrict(process.env.KEEPER_EXPIRE_OFFERS_BACKOFF_MAX_SECS, { defaultValue: 86_400 }) ??
      86_400,
    { min: 60, max: 604_800 },
  );

  const expireOffersBackoffMultiplier = clamp(
    parseIntStrict(process.env.KEEPER_EXPIRE_OFFERS_BACKOFF_MULTIPLIER, { defaultValue: 3 }) ?? 3,
    { min: 1, max: 10 },
  );

  const expireOffersBackoffJitterBps = clamp(
    parseIntStrict(process.env.KEEPER_EXPIRE_OFFERS_BACKOFF_JITTER_BPS, { defaultValue: 500 }) ??
      500,
    { min: 0, max: 5_000 },
  );

  const expireOffersBackoffInitialMs = expireOffersBackoffInitialSecs * 1000;
  const expireOffersBackoffMaxMs = Math.max(
    expireOffersBackoffInitialMs,
    expireOffersBackoffMaxSecs * 1000,
  );

  const stateDirRaw = process.env.KEEPER_STATE_DIR ?? './state';
  const stateDir = resolveMaybeRelative(stateDirRaw) as string;
  const deploymentStateDir = path.join(stateDir, deployment);
  ensureDir(deploymentStateDir);

  const pauseFilePathRaw = process.env.KEEPER_PAUSE_FILE;
  const pauseFilePath = pauseFilePathRaw
    ? (resolveMaybeRelative(pauseFilePathRaw) as string)
    : path.join(deploymentStateDir, 'PAUSED');

  ensureDir(path.dirname(pauseFilePath));

  // Circuit breaker (auto-pause on consecutive tx failures).
  const circuitBreakerEnabled = parseBool(process.env.KEEPER_CIRCUIT_BREAKER_ENABLED, {
    defaultValue: true,
  });

  const circuitBreakerMaxFailures = clamp(
    parseIntStrict(process.env.KEEPER_CIRCUIT_BREAKER_MAX_FAILURES, { defaultValue: 3 }) ?? 3,
    { min: 1, max: 100 },
  );

  const circuitBreakerCooldownSecs = clamp(
    parseIntStrict(process.env.KEEPER_CIRCUIT_BREAKER_COOLDOWN_SECS, { defaultValue: 3600 }) ??
      3600,
    { min: 60, max: 604_800 },
  );
  const circuitBreakerCooldownMs = circuitBreakerCooldownSecs * 1000;

  const circuitBreakerStatePath = path.join(deploymentStateDir, 'circuit_breaker.json');

  const statusPath = path.join(deploymentStateDir, 'status.json');
  const marketStatePath = path.join(deploymentStateDir, 'market.json');
  const listingsStatePath = path.join(deploymentStateDir, 'listings.json');
  const expireOffersStatePath = path.join(deploymentStateDir, 'expire_offers.json');
  const compoundShareholdersStatePath = path.join(deploymentStateDir, 'compound_shareholders.json');
  const compoundLpStatePath = path.join(deploymentStateDir, 'compound_lp.json');
  const checkpointBeforeExpiryStatePath = path.join(
    deploymentStateDir,
    'checkpoint_before_expiry.json',
  );
  const automaxBonusStatePath = path.join(deploymentStateDir, 'automax_bonus.json');

  const lockPathRaw = process.env.KEEPER_LOCK_PATH;
  const lockPath = lockPathRaw
    ? (resolveMaybeRelative(lockPathRaw) as string)
    : path.join(deploymentStateDir, 'keeper.lock');

  // Host-scoped lock (abstract UNIX socket).  Keyed on (uid, deployment)
  // so two keeper processes running as the same OS user targeting the same
  // deployment ALWAYS contend, even when their `KEEPER_STATE_DIR`s differ
  // (symlinks, relative paths, copied env files, hand-rolled `nohup`
  // daemons alongside a systemd unit, …).  The operator can override the
  // name with `KEEPER_HOST_LOCK_NAME` or disable the second lock entirely
  // by setting that variable to an empty string (not recommended).
  const hostLockNameRaw = process.env.KEEPER_HOST_LOCK_NAME;
  let hostLockName: string | null;
  if (hostLockNameRaw == null) {
    const uid =
      typeof (process as { getuid?: () => number }).getuid === 'function'
        ? (process as { getuid: () => number }).getuid()
        : 0;
    hostLockName = `claimrush-keeper-${deployment}-${uid}`;
  } else if (hostLockNameRaw.trim() === '') {
    hostLockName = null;
  } else {
    hostLockName = hostLockNameRaw.trim();
  }

  const lockTtlSecs = clamp(
    parseIntStrict(process.env.KEEPER_LOCK_TTL_SECS, { defaultValue: 600 }) ?? 600,
    {
      min: 30,
      max: 86_400,
    },
  );
  const lockHeartbeatSecs = clamp(
    parseIntStrict(process.env.KEEPER_LOCK_HEARTBEAT_SECS, { defaultValue: 60 }) ?? 60,
    { min: 5, max: lockTtlSecs },
  );

  // Health server (optional; primarily used for daemon monitoring).
  // Disabled by default (port=0).
  const healthPort = clamp(
    parseIntStrict(process.env.KEEPER_HEALTH_PORT, { defaultValue: 0 }) ?? 0,
    { min: 0, max: 65_535 },
  );

  const healthHost = String(process.env.KEEPER_HEALTH_HOST ?? '127.0.0.1').trim() || '127.0.0.1';

  const healthTokenRaw = process.env.KEEPER_HEALTH_TOKEN;
  const healthToken =
    healthTokenRaw != null && String(healthTokenRaw).trim() ? String(healthTokenRaw).trim() : null;

  // Safety: do not accidentally expose /metrics and /healthz on a public interface without auth.
  if (healthPort > 0) {
    const h = healthHost.toLowerCase();
    const isLoopback = h === '127.0.0.1' || h === 'localhost' || h === '::1';
    if (!isLoopback && !healthToken) {
      throw new Error(
        'Refusing to bind health server to a non-loopback host without KEEPER_HEALTH_TOKEN. ' +
          'Set KEEPER_HEALTH_TOKEN or bind KEEPER_HEALTH_HOST to 127.0.0.1.',
      );
    }
  }

  const alertWebhookUrlRaw = process.env.KEEPER_ALERT_WEBHOOK_URL;
  const alertWebhookUrl =
    alertWebhookUrlRaw != null && String(alertWebhookUrlRaw).trim()
      ? String(alertWebhookUrlRaw).trim()
      : null;

  // Low-gas floor: KEEPER_GAS_BALANCE_MIN_WEI (precise) wins over the friendlier
  // decimal KEEPER_GAS_BALANCE_MIN_ETH. Either being set arms the check.
  const gasBalanceMinWei =
    parseBigIntNullableEnv(process.env.KEEPER_GAS_BALANCE_MIN_WEI, 'KEEPER_GAS_BALANCE_MIN_WEI') ??
    etherStringToWei(process.env.KEEPER_GAS_BALANCE_MIN_ETH, 'KEEPER_GAS_BALANCE_MIN_ETH');
  const gasBalanceCheckIntervalSecs = parseIntStrictEnv(
    process.env.KEEPER_GAS_BALANCE_CHECK_INTERVAL_SECS,
    'KEEPER_GAS_BALANCE_CHECK_INTERVAL_SECS',
    { defaultValue: 1800 },
  );
  const gasBalanceAlertRepeatSecs = parseIntStrictEnv(
    process.env.KEEPER_GAS_BALANCE_ALERT_REPEAT_SECS,
    'KEEPER_GAS_BALANCE_ALERT_REPEAT_SECS',
    { defaultValue: 21_600 },
  );

  const cfg: KeeperConfig = {
    deployment,
    publicRpcUrl,
    privateRpcUrl,
    publicRpcAuthToken,
    privateRpcAuthToken,

    publicRpcTimeoutMs,
    privateRpcTimeoutMs,
    rpcRetryCount,
    rpcBatchWaitMs,

    multicall3Address,
    multicall3BlockCreated,

    wsUrl,
    wsUrlFallback,
    eventDrivenTasks,
    safetyNetIntervalSecs,
    wsDisconnectedGraceSecs,
    eventMinRepeatSecs,

    privateKey,
    expectedAccountAddress,

    dryRun,
    liveRun,
    allowUnsafeMinOut,
    allowUnsafeMinVeOut,

    paused,
    pauseFilePath,

    txConfirmations,
    txReceiptTimeoutMs,
    txMaxFeePerGasWei,
    txMaxPriorityFeePerGasWei,
    txMaxTotalFeeWei,
    txGasLimitMultiplierBps,
    txMaxGasLimit,
    allowTxWhilePending,

    circuitBreakerEnabled,
    circuitBreakerMaxFailures,
    circuitBreakerCooldownMs,
    circuitBreakerStatePath,

    intervalSecs,
    intervalSecsPrimary,
    intervalSecsFallback,

    daemonTasks,
    daemonJitterBps,
    daemonLockWaitSecs,

    pokeIntervalSecs,
    sweepMarketIntervalSecs,
    sweepListingsIntervalSecs,
    expireOffersIntervalSecs,
    harvestStakingIntervalSecs,
    compoundShareholdersIntervalSecs,
    compoundLpIntervalSecs,
    checkpointBeforeExpiryIntervalSecs,
    automaxBonusIntervalSecs,

    deadlineSecs,
    maxOffers,
    maxListings,
    maxExpireOffers,
    slippageBpsStaking,

    compoundSlippageBpsShareholders,
    compoundSlippageBpsLp,
    compoundMaxUsersShareholders,
    compoundMaxUsersLp,
    compoundLookaheadUsers,
    compoundScanChunkBlocks,
    compoundShareholdersStartBlock,
    compoundLpStartBlock,
    compoundMaxGas,
    compoundLpMinReward,
    harvestStakingMinReward,

    marketScanChunkBlocks,
    marketStartBlockOverride,

    autoFurnaceBackoffEnabled,
    autoFurnacePreflightEnabled,
    autoFurnaceBackoffInitialMs,
    autoFurnaceBackoffMaxMs,
    autoFurnaceBackoffMultiplier,
    autoFurnaceBackoffJitterBps,

    listingsBackoffEnabled,
    listingsPreflightEnabled,
    listingsBackoffInitialMs,
    listingsBackoffMaxMs,
    listingsBackoffMultiplier,
    listingsBackoffJitterBps,
    listingsStartBlockOverride,

    expireOffersBackoffEnabled,
    expireOffersPreflightEnabled,
    expireOffersBackoffInitialMs,
    expireOffersBackoffMaxMs,
    expireOffersBackoffMultiplier,
    expireOffersBackoffJitterBps,

    stateDir,
    deploymentStateDir,
    statusPath,
    marketStatePath,
    listingsStatePath,
    expireOffersStatePath,
    compoundShareholdersStatePath,
    compoundLpStatePath,
    checkpointBeforeExpiryStatePath,
    pokeStaleThresholdSecs,
    pokeLpTickIntervalSecs,
    pokeMinPendingEthDelta,
    pokeTakeoverScanChunkBlocks,
    pokeStatePath: path.join(deploymentStateDir, 'poke.json'),

    automaxBonusStatePath,

    checkpointBeforeExpiryStartBlock,
    checkpointBeforeExpiryScanChunkBlocks,
    checkpointBeforeExpiryWindowSecs,
    checkpointBeforeExpiryMaxUsers,

    automaxBonusStartBlock,
    automaxBonusScanChunkBlocks,
    automaxBonusMaxLocks,
    automaxBonusMinReward,

    settlementEnabled,
    settlementPeriodSecs,
    settlementDayUtc,
    settlementHourUtc,
    settlementWindowDurationSecs,
    settlementTaskGapSecs,
    settlementRetryWindowSecs,
    settlementMaxDriftBps,
    settlementStatePath: path.join(deploymentStateDir, 'settlement.json'),

    compoundShareholderMinCadenceSecs,
    compoundShareholderSpreadSecs,
    compoundLpMinCadenceSecs,
    automaxOwnerCooldownSecs,

    subgraphUrl,
    morningWindowHours,
    morningCachePath: path.join(deploymentStateDir, 'user_mornings.json'),

    lockPath,
    lockTtlMs: lockTtlSecs * 1000,
    lockHeartbeatMs: lockHeartbeatSecs * 1000,
    hostLockName,

    healthHost,
    healthPort,
    healthToken,

    alertWebhookUrl,

    gasBalanceMinWei,
    gasBalanceCheckIntervalSecs,
    gasBalanceAlertRepeatSecs,
  };

  // Validate the fully-parsed config with zod so missing or malformed values
  // fail fast at startup rather than mid-execution.
  //
  // SECURITY: Replace the real private key with a syntactically valid placeholder
  // before validation so that Zod error messages (which may include field values)
  // never contain the actual key material.
  const realKey = cfg.privateKey;
  const cfgForValidation = {
    ...cfg,
    // pragma: allowlist secret
    privateKey: cfg.privateKey ? '0x' + 'ab'.repeat(32) : cfg.privateKey, // pragma: allowlist secret
  };
  const parsed = KeeperConfigSchema.safeParse(cfgForValidation);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Keeper config validation failed:\n${issues}`);
  }
  // Restore the real key after successful validation.
  cfg.privateKey = realKey;

  return cfg;
}
