// Client-side achievement/badge engine.
//
// Badges are display-only and have no on-chain effect, so this module
// intentionally treats its inputs (subgraph-sourced user counters, in-memory
// event stream) as best-effort. Callers that want hard freshness guarantees
// should check subgraph meta/indexing lag themselves before relying on badge
// unlocks for anything beyond UI surfacing.

import type { Address, Hash } from 'viem';

import type { ClaimRushEvent } from '../events.js';
import type { ClaimRushSnapshot } from '../snapshot.js';
import type { AgentAction, AgentActionResult } from '../agent/types.js';
import { SubgraphClient, getSubgraphMeta } from '../subgraph.js';

import type { ClaimRushErrorInfo } from '../errors.js';
import { readResponseTextLimited } from '../security/fetch.js';

import {
  DEFAULT_PUBLIC_HTTP_URL_POLICY,
  fetchRedirectMode,
  parseAndValidateOutboundUrl,
  parseAndValidateOutboundUrlWithDns,
  type OutboundUrlPolicy,
} from '../security/url.js';

import type { Achievement, AchievementKind, AchievementWriter } from './types.js';

import {
  PROFILE_BADGES,
  badgeLabelWithTier,
  getBadgeTierPriority,
  getBadgeTierRarity,
  type ProfileBadge,
  type ProfileBadgeId,
} from './profileBadges.js';

function normAddr(a: string | Address): string {
  return String(a).toLowerCase();
}

function asBigInt(v: unknown): bigint | undefined {
  if (typeof v === 'bigint') return v;
  if (typeof v === 'number' && Number.isFinite(v)) return BigInt(v);
  if (typeof v === 'string' && v.trim()) {
    try {
      return BigInt(v);
    } catch {
      return undefined;
    }
  }
  return undefined;
}

// 0x + 40 hex chars. We validate hex-ness explicitly rather than trusting
// the length alone; without this, any 42-char string starting with 0x would
// be treated as an Address and flow into normAddr / analytics / payloads,
// producing confusing downstream errors ("not a hex" vs "not an address").
const HEX_ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const HEX_HASH_RE = /^0x[0-9a-fA-F]{64}$/;

function asAddress(v: unknown): Address | undefined {
  if (typeof v === 'string' && HEX_ADDRESS_RE.test(v)) return v as Address;
  return undefined;
}

function _asHash(v: unknown): Hash | undefined {
  if (typeof v === 'string' && HEX_HASH_RE.test(v)) return v as Hash;
  return undefined;
}

function normalizeTier(value: number | null | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0;
  return Math.max(0, Math.floor(value));
}

function computeBonusBps(
  principalClaim: bigint | undefined,
  bonusClaim: bigint | undefined,
): bigint | undefined {
  if (!principalClaim || principalClaim === 0n) return undefined;
  if (!bonusClaim) return undefined;
  return (bonusClaim * 10_000n) / principalClaim;
}

function classifyPausedFeature(
  errorName: string | undefined,
): 'takeovers' | 'locking' | 'trading' | 'unknown' {
  if (!errorName) return 'unknown';
  if (errorName === 'TakeoversPaused') return 'takeovers';
  if (errorName === 'LockingPaused') return 'locking';
  if (errorName === 'TradingPaused') return 'trading';
  return 'unknown';
}

export type AchievementEngineOptions = {
  chain: string;
  chainId: number;
  agent: Address;
  user: Address;

  write: AchievementWriter;

  /** Optional subgraph endpoint for health checks (lag detection). */
  subgraphUrl?: string;

  /** Optional outbound URL policy for achievements/subgraph HTTP calls. */
  outboundUrlPolicy?: OutboundUrlPolicy;

  /** Default: 200 blocks. */
  subgraphLagThresholdBlocks?: number;

  /** Default: 60s. */
  subgraphCheckIntervalMs?: number;

  /** Default: disabled (0). */
  rpcLagThresholdSeconds?: number;

  /** Default: 60s. Only emit rpc lag if blocks have advanced recently. */
  rpcLagRecentBlockChangeWindowSeconds?: number;

  /**
   * Optional base URL for an achievements HTTP API that exposes
   * `/api/achievements?address=<user>&chainId=<chainId>` and returns the
   * live badge set for a user on a given chain.
   *
   * ClaimRush operates such an endpoint, but this SDK does NOT assume any
   * specific hosting; any service that matches the documented JSON shape
   * works. When set, the engine polls the endpoint and emits
   * `BADGE_UNLOCKED` achievements for newly unlocked (or tier-upgraded)
   * badges. Leave unset to disable achievement polling entirely.
   */
  achievementsBaseUrl?: string;

  /** Default: 20s. */
  achievementsPollIntervalMs?: number;

  /** Default: 5s. Debounce for forced refreshes after tx confirmations. */
  achievementsForceRefreshCooldownMs?: number;

  /** Default: 10s. */
  achievementsFetchTimeoutMs?: number;

  /** Emit ACTION_UTILITY achievements for planned actions (default: false). */
  emitActionUtility?: boolean;

  /**
   * Max size for the internal achievement de-dup cache.
   *
   * Safety: without a cap, long-running agents can accumulate unbounded memory in the dedup Set.
   *
   * Default: 20_000.
   */
  maxDedupKeys?: number;
};

export type AchievementTickInputs = {
  snapshot: ClaimRushSnapshot;
  config?: {
    enableTakeovers?: boolean;
    enableFurnaceEntry?: boolean;
  };
  delegation?: {
    expiry: bigint;
    perms: bigint;
  };
};

export class AchievementEngine {
  private readonly write: AchievementWriter;
  private readonly chain: string;
  private readonly chainId: number;
  private readonly agent: Address;
  private readonly user: Address;

  private readonly outboundUrlPolicy?: OutboundUrlPolicy;

  private readonly subgraphUrl?: string;
  private readonly subgraphLagThresholdBlocks: number;
  private readonly subgraphCheckIntervalMs: number;

  private readonly rpcLagThresholdSeconds: number;
  private readonly rpcLagRecentBlockChangeWindowSeconds: number;

  private readonly achievementsBaseUrl?: string;
  private readonly achievementsPollIntervalMs: number;
  private readonly achievementsForceRefreshCooldownMs: number;
  private readonly achievementsFetchTimeoutMs: number;

  private readonly badgeDefById: Map<string, ProfileBadge>;

  // Badge polling state
  private badgesInitialized = false;
  private badgeBaseline = new Map<string, number>();
  private lastBadgesPollMs = 0;
  private pendingBadgesForceRefresh = false;
  private lastBadgesForceRefreshMs = 0;

  private readonly emitActionUtility: boolean;

  // De-dup keys to avoid emitting the same achievement multiple times.
  // NOTE: bounded to avoid unbounded memory growth in long-running agents.
  private readonly seen = new Set<string>();
  private readonly seenKeys: string[] = [];
  private seenHead = 0;
  private readonly maxDedupKeys: number;

  // Pause/session state
  private lastTakeoversPaused: boolean | undefined;
  private lastLockingPaused: boolean | undefined;
  private lastSessionActive: boolean | undefined;
  private lastSessionExpiry: bigint | undefined;

  // Health checks
  private lastSubgraphCheckMs = 0;
  private lastSubgraphLagBlocks: bigint | undefined;
  private lastRpcLagEmitMs = 0;

  private lastHeadBlock: bigint | undefined;
  private lastHeadBlockChangedAtMs = 0;

  // Set once the first time `maybePollBadges` is called on a chainId that is
  // not in the supported set (Base mainnet, Base Sepolia, local Anvil). This
  // prevents integrators silently wondering why badge polling never runs on
  // exotic chains: see `maybePollBadges` below.
  private loggedUnsupportedChain = false;

  constructor(opts: AchievementEngineOptions) {
    this.write = opts.write;
    this.chain = opts.chain;
    this.chainId = opts.chainId;
    this.agent = opts.agent;
    this.user = opts.user;
    // Default to stricter SSRF hardening for public HTTP endpoints on non-local chains.
    const defaultPolicy = this.chainId === 31337 ? undefined : DEFAULT_PUBLIC_HTTP_URL_POLICY;
    this.outboundUrlPolicy = opts.outboundUrlPolicy ?? defaultPolicy;

    this.subgraphUrl = opts.subgraphUrl
      ? parseAndValidateOutboundUrl(
          opts.subgraphUrl,
          'AchievementEngine.subgraphUrl',
          this.outboundUrlPolicy,
        ).toString()
      : undefined;
    this.subgraphLagThresholdBlocks = opts.subgraphLagThresholdBlocks ?? 200;
    this.subgraphCheckIntervalMs = opts.subgraphCheckIntervalMs ?? 60_000;

    this.rpcLagThresholdSeconds = opts.rpcLagThresholdSeconds ?? 0;
    this.rpcLagRecentBlockChangeWindowSeconds = opts.rpcLagRecentBlockChangeWindowSeconds ?? 60;

    this.achievementsBaseUrl = opts.achievementsBaseUrl
      ? parseAndValidateOutboundUrl(
          opts.achievementsBaseUrl,
          'AchievementEngine.achievementsBaseUrl',
          this.outboundUrlPolicy,
        ).toString()
      : undefined;
    this.achievementsPollIntervalMs = opts.achievementsPollIntervalMs ?? 20_000;
    this.achievementsForceRefreshCooldownMs = opts.achievementsForceRefreshCooldownMs ?? 5_000;
    this.achievementsFetchTimeoutMs = opts.achievementsFetchTimeoutMs ?? 10_000;

    this.badgeDefById = new Map(PROFILE_BADGES.map((b) => [b.id, b]));

    this.emitActionUtility = opts.emitActionUtility ?? false;

    const rawMax = opts.maxDedupKeys;
    const n = typeof rawMax === 'number' && Number.isFinite(rawMax) ? Math.floor(rawMax) : 20_000;
    // Keep this reasonably sized to preserve dedup behavior, but always bounded.
    this.maxDedupKeys = Math.max(100, n);
  }

  private rememberDedupKey(key: string): boolean {
    // is exceeded. For long-running agents, this means an achievement emitted
    // early in the session can be re-emitted after the dedup key is evicted.
    // This is documented via maxDedupKeys, but downstream consumers (badge
    // polling, telemetry dashboards) should be aware of potential duplicates.
    // FIX: Consider using a Bloom filter for space-efficient dedup, or
    //      persisting dedup state to disk for restart resilience.
    if (this.seen.has(key)) return false;
    this.seen.add(key);
    this.seenKeys.push(key);

    // Evict oldest keys when exceeding capacity.
    while (this.seenKeys.length - this.seenHead > this.maxDedupKeys) {
      const old = this.seenKeys[this.seenHead++];
      if (old !== undefined) this.seen.delete(old);
    }

    // Periodically compact the array to keep it from growing without bound.
    if (this.seenHead > 1000 && this.seenHead > this.seenKeys.length / 2) {
      this.seenKeys.splice(0, this.seenHead);
      this.seenHead = 0;
    }

    return true;
  }

  private emit(
    kind: AchievementKind,
    level: 'info' | 'warn' | 'error',
    params: {
      blockNumber?: bigint;
      blockTimestamp?: bigint;
      txHash?: Hash;
      dedup?: string;
      data?: Record<string, unknown>;
    },
  ): void {
    const a: Achievement = {
      ts: Date.now(),
      kind,
      level,
      chain: this.chain,
      chainId: this.chainId,
      agent: this.agent,
      user: this.user,
      blockNumber: params.blockNumber,
      blockTimestamp: params.blockTimestamp,
      txHash: params.txHash,
      data: params.data,
    };

    const key =
      params.dedup ?? `${kind}|${params.txHash ?? ''}|${params.blockNumber?.toString() ?? ''}`;
    if (!this.rememberDedupKey(key)) return;

    this.write(a);
  }

  private requestBadgesRefresh(): void {
    if (!this.achievementsBaseUrl) return;
    this.pendingBadgesForceRefresh = true;
  }

  private async maybePollBadges(snap: ClaimRushSnapshot): Promise<void> {
    if (!this.achievementsBaseUrl) return;

    // Keep parity with the frontend: achievements are only supported on Base
    // mainnet, Base sepolia, and local Anvil. Integrators pointing the engine
    // at any other chain will never see badges appear; emit a single
    // structured stderr line on the first tick so this is not silent.
    const supported = this.chainId === 8453 || this.chainId === 84532 || this.chainId === 31337;
    if (!supported) {
      if (!this.loggedUnsupportedChain) {
        this.loggedUnsupportedChain = true;
        try {
          // eslint-disable-next-line no-console -- one-time diagnostic; SDK does not carry a logger dependency.
          console.info(
            JSON.stringify({
              level: 'info',
              event: 'achievements_disabled_for_chain',
              chainId: this.chainId,
              chain: this.chain,
              message:
                'Achievements polling is only supported on Base mainnet (8453), Base Sepolia (84532), and local Anvil (31337). No badges will be polled on this chain.',
            }),
          );
        } catch {
          /* best-effort diagnostic */
        }
      }
      return;
    }

    const nowMs = Date.now();

    const pollDue = nowMs - this.lastBadgesPollMs >= this.achievementsPollIntervalMs;
    const refreshDue =
      this.pendingBadgesForceRefresh &&
      nowMs - this.lastBadgesForceRefreshMs >= this.achievementsForceRefreshCooldownMs;

    if (!pollDue && !refreshDue) return;

    const refresh = refreshDue;

    // Debounce forced refreshes.
    if (refresh) {
      this.pendingBadgesForceRefresh = false;
      this.lastBadgesForceRefreshMs = nowMs;
    }

    this.lastBadgesPollMs = nowMs;

    await this.pollBadgesOnce({ snap, refresh });
  }

  private async pollBadgesOnce(params: {
    snap: ClaimRushSnapshot;
    refresh: boolean;
  }): Promise<void> {
    type ApiAchievement = { id: string; tier: number | null; unlockedAt: number | null };

    let body: any;

    try {
      const url = new URL('/api/achievements', this.achievementsBaseUrl);
      url.searchParams.set('address', this.user);
      url.searchParams.set('chainId', String(this.chainId));
      if (params.refresh) url.searchParams.set('refresh', '1');

      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), Math.max(1, this.achievementsFetchTimeoutMs));

      try {
        const safeUrl = await parseAndValidateOutboundUrlWithDns(
          url.toString(),
          'AchievementEngine.achievementsFetchUrl',
          this.outboundUrlPolicy,
        );

        const res = await fetch(safeUrl.toString(), {
          method: 'GET',
          redirect: fetchRedirectMode(this.outboundUrlPolicy) as any,
          signal: ctrl.signal,
        });

        if (!res.ok) return;

        // Avoid unbounded memory usage from misconfigured or malicious endpoints.
        const { text: bodyText, truncated } = await readResponseTextLimited(res, 1_000_000);
        if (truncated) return;

        try {
          body = JSON.parse(bodyText);
        } catch {
          return;
        }
      } finally {
        clearTimeout(t);
      }
    } catch {
      return;
    }

    const MAX_BADGE_ENTRIES = 500;
    const raw = Array.isArray(body?.achievements)
      ? (body.achievements as ApiAchievement[]).slice(0, MAX_BADGE_ENTRIES)
      : [];

    const current = new Map<string, number>();
    const byId = new Map<string, ApiAchievement>();

    for (const a of raw) {
      const id = typeof (a as any)?.id === 'string' ? String((a as any).id) : '';
      if (!id) continue;
      if (!this.badgeDefById.has(id)) continue;

      const tier = normalizeTier((a as any)?.tier as any);
      current.set(id, tier);
      byId.set(id, a);
    }

    // First poll only initializes the baseline (no achievements emitted).
    if (!this.badgesInitialized) {
      this.badgesInitialized = true;
      this.badgeBaseline = current;
      return;
    }

    const prior = this.badgeBaseline;
    const unlocked: { id: ProfileBadgeId; tier: number | null; unlockedAt: number | null }[] = [];

    for (const [id, nextTier] of current.entries()) {
      const hadBefore = prior.has(id);
      const prevTier = prior.get(id) ?? 0;
      if (hadBefore && nextTier <= prevTier) continue;

      const a = byId.get(id);
      unlocked.push({
        id: id as ProfileBadgeId,
        tier: (a?.tier ?? null) as any,
        unlockedAt: (a?.unlockedAt ?? null) as any,
      });
    }

    // Update baseline even if we emit nothing (prevents repeats).
    this.badgeBaseline = current;

    if (!unlocked.length) return;

    // Sort: older unlocks first, then by configured priority (lower is better), then stable by id+tier.
    unlocked.sort((a, b) => {
      const atA = a.unlockedAt ?? Number.POSITIVE_INFINITY;
      const atB = b.unlockedAt ?? Number.POSITIVE_INFINITY;
      if (atA !== atB) return atA - atB;

      const defA = this.badgeDefById.get(a.id);
      const defB = this.badgeDefById.get(b.id);
      const pA = defA ? getBadgeTierPriority(defA, a.tier) : 999;
      const pB = defB ? getBadgeTierPriority(defB, b.tier) : 999;
      if (pA !== pB) return pA - pB;

      const idA = `${a.id}:${a.tier ?? ''}`;
      const idB = `${b.id}:${b.tier ?? ''}`;
      return idA.localeCompare(idB);
    });

    const rulesVersion = typeof body?.rulesVersion === 'number' ? body.rulesVersion : undefined;
    const computed = typeof body?.computed === 'number' ? body.computed : undefined;

    for (const u of unlocked) {
      const def = this.badgeDefById.get(u.id);
      if (!def) continue;

      const rarity = getBadgeTierRarity(def, u.tier);
      const displayLabel = badgeLabelWithTier(def.label, u.tier);

      this.emit('BADGE_UNLOCKED', 'info', {
        blockNumber: params.snap.meta.blockNumber,
        blockTimestamp: params.snap.meta.blockTimestamp,
        dedup: `BADGE_UNLOCKED|${u.id}|${u.tier ?? 0}|${u.unlockedAt ?? ''}`,
        data: {
          badgeId: def.id,
          category: def.category,
          label: displayLabel,
          tier: u.tier,
          rarity,
          unlockedAt: u.unlockedAt,
          rulesVersion,
          computed,
          source: params.refresh ? 'achievements_api:refresh' : 'achievements_api:poll',
        },
      });
    }
  }

  // ------------------------------------------------------------
  // Inputs
  // ------------------------------------------------------------

  onEvent(ev: ClaimRushEvent): void {
    const args = ev.args ?? {};

    // TAKEOVER_SUCCESS (MineCore.Takeover)
    if (ev.contract === 'MineCore' && ev.event === 'Takeover') {
      const newKing = asAddress(args.newKing);
      if (!newKing) return;
      if (normAddr(newKing) !== normAddr(this.user)) return;

      const reignId = asBigInt(args.reignId);
      const previousKing = asAddress(args.previousKing);
      const pricePaid = asBigInt(args.pricePaid);
      const referencePrice = asBigInt(args.referencePrice);
      const ts = asBigInt(args.timestamp);

      this.emit('TAKEOVER_SUCCESS', 'info', {
        blockNumber: ev.blockNumber,
        blockTimestamp: ev.blockTimestamp ?? ts,
        txHash: ev.transactionHash,
        dedup: `TAKEOVER_SUCCESS|${ev.transactionHash}|${ev.logIndex}`,
        data: {
          reignId: reignId?.toString(),
          previousKing,
          newKing,
          ethSpentWei: pricePaid?.toString(),
          takeoverPriceWei: pricePaid?.toString(),
          referencePriceWei: referencePrice?.toString(),
          source: ev.source ?? 'rpc',
        },
      });

      return;
    }

    // ROYALTIES_CLAIMED (ShareholderRoyalties.ShareholderClaim)
    if (ev.contract === 'ShareholderRoyalties' && ev.event === 'ShareholderClaim') {
      const user = asAddress(args.user);
      if (!user) return;
      if (normAddr(user) !== normAddr(this.user)) return;

      const mode = asBigInt(args.mode);
      const amountEth = asBigInt(args.amountEth);

      this.emit('ROYALTIES_CLAIMED', 'info', {
        blockNumber: ev.blockNumber,
        blockTimestamp: ev.blockTimestamp,
        txHash: ev.transactionHash,
        dedup: `ROYALTIES_CLAIMED|${ev.transactionHash}|${ev.logIndex}`,
        data: {
          user,
          mode: mode?.toString(),
          ethOutWei: amountEth?.toString(),
          source: ev.source ?? 'rpc',
        },
      });

      return;
    }

    // AUTOCOMPOUND_EXECUTED (ShareholderRoyalties.ShareholderAutoCompoundExecuted)
    if (ev.contract === 'ShareholderRoyalties' && ev.event === 'ShareholderAutoCompoundExecuted') {
      const user = asAddress(args.user);
      if (!user) return;
      if (normAddr(user) !== normAddr(this.user)) return;

      const executor = asAddress(args.executor);
      const amountEth = asBigInt(args.amountEth);
      const tokenId = asBigInt(args.tokenId);
      const effectiveDurationSeconds = asBigInt(args.effectiveDurationSeconds);

      this.emit('AUTOCOMPOUND_EXECUTED', 'info', {
        blockNumber: ev.blockNumber,
        blockTimestamp: ev.blockTimestamp,
        txHash: ev.transactionHash,
        dedup: `AUTOCOMPOUND_EXECUTED|${ev.transactionHash}|${ev.logIndex}`,
        data: {
          user,
          executor,
          ethInWei: amountEth?.toString(),
          tokenId: tokenId?.toString(),
          effectiveDurationSeconds: effectiveDurationSeconds?.toString(),
          source: ev.source ?? 'rpc',
        },
      });

      return;
    }

    // FURNACE_LOCK_CREATED (Furnace.FurnaceEnter)
    if (ev.contract === 'Furnace' && ev.event === 'FurnaceEnter') {
      const user = asAddress(args.user);
      if (!user) return;
      if (normAddr(user) !== normAddr(this.user)) return;

      const mode = asBigInt(args.mode);
      const ethIn = asBigInt(args.ethIn);
      const principalClaim = asBigInt(args.principalClaim);
      const bonusClaim = asBigInt(args.bonusClaim);
      const tokenId = asBigInt(args.tokenId);

      const claimIn = principalClaim && bonusClaim ? principalClaim + bonusClaim : undefined;
      const bonusBps = computeBonusBps(principalClaim, bonusClaim);

      this.emit('FURNACE_LOCK_CREATED', 'info', {
        blockNumber: ev.blockNumber,
        blockTimestamp: ev.blockTimestamp,
        txHash: ev.transactionHash,
        dedup: `FURNACE_LOCK_CREATED|${ev.transactionHash}|${ev.logIndex}`,
        data: {
          user,
          mode: mode?.toString(),
          ethInWei: ethIn?.toString(),
          principalClaimWei: principalClaim?.toString(),
          bonusClaimWei: bonusClaim?.toString(),
          claimInWei: claimIn?.toString(),
          bonusBps: bonusBps?.toString(),
          tokenId: tokenId?.toString(),
          source: ev.source ?? 'rpc',
        },
      });

      return;
    }

    // Optional: MineCore.KingWithdrawal -> REIGN_REWARD_COLLECTED
    if (ev.contract === 'MineCore' && ev.event === 'KingWithdrawal') {
      const king = asAddress(args.king);
      if (!king) return;
      // In self-play, king == user. In delegated mode, king bucket may be routed to the delegate.
      const tracked =
        normAddr(king) === normAddr(this.user) || normAddr(king) === normAddr(this.agent);
      if (!tracked) return;

      const amount = asBigInt(args.amount);

      this.emit('REIGN_REWARD_COLLECTED', 'info', {
        blockNumber: ev.blockNumber,
        blockTimestamp: ev.blockTimestamp,
        txHash: ev.transactionHash,
        dedup: `REIGN_REWARD_COLLECTED|${ev.transactionHash}|${ev.logIndex}`,
        data: {
          bucket: 'king',
          recipient: king,
          ethOutWei: amount?.toString(),
          source: ev.source ?? 'rpc',
        },
      });
    }
  }

  async onTick(input: AchievementTickInputs): Promise<void> {
    const snap = input.snapshot;
    const headBlock = snap.meta.blockNumber;

    // Track recent head movement.
    if (this.lastHeadBlock === undefined) {
      this.lastHeadBlock = headBlock;
      this.lastHeadBlockChangedAtMs = Date.now();
    } else if (headBlock > this.lastHeadBlock) {
      this.lastHeadBlock = headBlock;
      this.lastHeadBlockChangedAtMs = Date.now();
    }

    // ----------------------------------------------------------
    // PAUSED_ACTION_SKIPPED (emit on transition to paused)
    // ----------------------------------------------------------

    const takeoversPaused = snap.mineCore.takeoversPaused;
    const lockingPaused = snap.furnace.lockingPaused;

    if (
      (input.config?.enableTakeovers ?? false) &&
      takeoversPaused &&
      this.lastTakeoversPaused !== true
    ) {
      this.emit('PAUSED_ACTION_SKIPPED', 'warn', {
        blockNumber: headBlock,
        blockTimestamp: snap.meta.blockTimestamp,
        dedup: `PAUSED_ACTION_SKIPPED|takeovers|${headBlock.toString()}`,
        data: {
          feature: 'takeovers',
          paused: true,
        },
      });
    }

    if (
      (input.config?.enableFurnaceEntry ?? false) &&
      lockingPaused &&
      this.lastLockingPaused !== true
    ) {
      this.emit('PAUSED_ACTION_SKIPPED', 'warn', {
        blockNumber: headBlock,
        blockTimestamp: snap.meta.blockTimestamp,
        dedup: `PAUSED_ACTION_SKIPPED|locking|${headBlock.toString()}`,
        data: {
          feature: 'locking',
          paused: true,
        },
      });
    }

    this.lastTakeoversPaused = takeoversPaused;
    this.lastLockingPaused = lockingPaused;

    // ----------------------------------------------------------
    // SESSION_EXPIRED (delegated mode)
    // ----------------------------------------------------------

    if (input.delegation) {
      const now = snap.meta.blockTimestamp;
      const expiry = input.delegation.expiry;
      const active = expiry !== 0n && expiry >= now;

      if (!active && (this.lastSessionActive !== false || this.lastSessionExpiry !== expiry)) {
        this.emit('SESSION_EXPIRED', 'error', {
          blockNumber: headBlock,
          blockTimestamp: snap.meta.blockTimestamp,
          dedup: `SESSION_EXPIRED|${expiry.toString()}`,
          data: {
            now: now.toString(),
            expiry: expiry.toString(),
          },
        });
      }

      this.lastSessionActive = active;
      this.lastSessionExpiry = expiry;
    }

    // ----------------------------------------------------------
    // SUBGRAPH_LAG_DETECTED
    // ----------------------------------------------------------

    if (this.subgraphUrl) {
      const nowMs = Date.now();
      if (nowMs - this.lastSubgraphCheckMs >= this.subgraphCheckIntervalMs) {
        this.lastSubgraphCheckMs = nowMs;

        try {
          const client = new SubgraphClient({
            url: this.subgraphUrl,
            networkPolicy: this.outboundUrlPolicy,
          });
          const meta = await getSubgraphMeta(client);
          if (!meta) return;
          const subgraphBlock = BigInt(meta.blockNumber);
          const lagBlocks = headBlock > subgraphBlock ? headBlock - subgraphBlock : 0n;

          const threshold = BigInt(Math.max(0, this.subgraphLagThresholdBlocks));

          if (lagBlocks > threshold && this.lastSubgraphLagBlocks !== lagBlocks) {
            this.lastSubgraphLagBlocks = lagBlocks;
            this.emit('SUBGRAPH_LAG_DETECTED', 'warn', {
              blockNumber: headBlock,
              blockTimestamp: snap.meta.blockTimestamp,
              dedup: `SUBGRAPH_LAG_DETECTED|${subgraphBlock.toString()}`,
              data: {
                headBlock: headBlock.toString(),
                subgraphBlock: subgraphBlock.toString(),
                lagBlocks: lagBlocks.toString(),
                thresholdBlocks: threshold.toString(),
              },
            });
          }
        } catch {
          // Ignore subgraph errors for now (subgraph may be down).
        }
      }
    }

    // ----------------------------------------------------------
    // RPC_LAG_DETECTED (best-effort)
    // ----------------------------------------------------------

    if (this.rpcLagThresholdSeconds > 0) {
      const nowMs = Date.now();
      const sinceHeadChangeMs = nowMs - this.lastHeadBlockChangedAtMs;
      const headChangeWindowMs = Math.max(1, this.rpcLagRecentBlockChangeWindowSeconds) * 1000;

      if (sinceHeadChangeMs <= headChangeWindowMs) {
        const nowSec = Math.floor(nowMs / 1000);
        const headTsSec = Number(snap.meta.blockTimestamp);
        const ageSec = Math.max(0, nowSec - headTsSec);

        if (ageSec >= this.rpcLagThresholdSeconds && nowMs - this.lastRpcLagEmitMs > 5 * 60_000) {
          this.lastRpcLagEmitMs = nowMs;
          this.emit('RPC_LAG_DETECTED', 'warn', {
            blockNumber: headBlock,
            blockTimestamp: snap.meta.blockTimestamp,
            dedup: `RPC_LAG_DETECTED|${headBlock.toString()}|${ageSec}`,
            data: {
              headTimestamp: snap.meta.blockTimestamp.toString(),
              ageSeconds: String(ageSec),
              thresholdSeconds: String(this.rpcLagThresholdSeconds),
            },
          });
        }
      }
    }
    // ----------------------------------------------------------
    // FRONTEND BADGES (optional)
    // ----------------------------------------------------------

    await this.maybePollBadges(snap);
  }

  onPlan(plan: { blockNumber: bigint; blockTimestamp: bigint; actions: AgentAction[] }): void {
    if (!this.emitActionUtility) return;

    for (const action of plan.actions) {
      const utility = scoreAction(action);
      this.emit('ACTION_UTILITY', 'info', {
        blockNumber: plan.blockNumber,
        blockTimestamp: plan.blockTimestamp,
        dedup: `ACTION_UTILITY|${plan.blockNumber.toString()}|${(action as any).kind}`,
        data: {
          actionKind: (action as any).kind,
          utilityWei: utility.toString(),
        },
      });
    }
  }

  onBackoff(ev: {
    kind: 'entered' | 'cleared';
    state: {
      cooldownUntilMs: number;
      cooldownMs: number;
      consecutiveErrors: number;
      consecutiveTimeouts: number;
      lastErrorKind?: string;
      lastErrorName?: string;
      lastActionKind?: string;
    };
    reason?: {
      errorKind?: string;
      errorName?: string;
      message?: string;
      actionKind?: string;
    };
  }): void {
    if (ev.kind === 'entered') {
      this.emit('BACKOFF_ENTERED', 'warn', {
        dedup: `BACKOFF_ENTERED|${ev.state.cooldownUntilMs}|${ev.reason?.errorKind ?? ''}`,
        data: {
          cooldownMs: ev.state.cooldownMs,
          cooldownUntilMs: ev.state.cooldownUntilMs,
          consecutiveErrors: ev.state.consecutiveErrors,
          consecutiveTimeouts: ev.state.consecutiveTimeouts,
          lastErrorKind: ev.state.lastErrorKind,
          lastErrorName: ev.state.lastErrorName,
          lastActionKind: ev.state.lastActionKind,
          reason: ev.reason,
        },
      });
      return;
    }

    this.emit('BACKOFF_CLEARED', 'info', {
      dedup: `BACKOFF_CLEARED|${ev.state.cooldownMs}`,
      data: {
        previousCooldownMs: ev.state.cooldownMs,
      },
    });
  }
  onActionResult(res: AgentActionResult): void {
    const action = res.action;

    // Best-effort structured error info.
    const errorInfo = (res as any).errorInfo as ClaimRushErrorInfo | undefined;
    const detailsErrorInfo = (res.details as any)?.errorInfo as ClaimRushErrorInfo | undefined;
    const info = errorInfo ?? detailsErrorInfo;

    if (res.error) {
      // Delegation session preflight errors.
      if (res.error.startsWith('Delegation session inactive/expired')) {
        this.emit('SESSION_EXPIRED', 'error', {
          blockNumber: res.receiptBlockNumber,
          txHash: res.hash,
          dedup: `SESSION_EXPIRED|${res.error}`,
          data: {
            error: res.error,
            actionKind: (action as any).kind,
          },
        });
        return;
      }

      if (info?.kind === 'slippage') {
        this.emit('SLIPPAGE_GUARD_TRIGGERED', 'warn', {
          blockNumber: res.receiptBlockNumber,
          txHash: res.hash,
          dedup: `SLIPPAGE_GUARD_TRIGGERED|${(action as any).kind}|${info.errorName ?? ''}|${res.hash ?? ''}`,
          data: {
            actionKind: (action as any).kind,
            errorName: info.errorName,
            message: info.message,
          },
        });
        return;
      }

      if (info?.kind === 'paused') {
        this.emit('PAUSED_ACTION_SKIPPED', 'warn', {
          blockNumber: res.receiptBlockNumber,
          txHash: res.hash,
          dedup: `PAUSED_ACTION_SKIPPED|${(action as any).kind}|${info.errorName ?? ''}|${res.hash ?? ''}`,
          data: {
            feature: classifyPausedFeature(info.errorName),
            actionKind: (action as any).kind,
            errorName: info.errorName,
            message: info.message,
          },
        });
        return;
      }

      this.emit('REVERTED_TX', 'error', {
        blockNumber: res.receiptBlockNumber,
        txHash: res.hash,
        dedup: `REVERTED_TX|${res.hash ?? ''}|${(action as any).kind}`,
        data: {
          actionKind: (action as any).kind,
          error: res.error,
          errorName: info?.errorName,
          kind: info?.kind ?? 'unknown',
        },
      });
      return;
    }

    // Success achievements from executed actions.
    if (res.simulated || !res.hash) {
      return;
    }

    // After a confirmed on-chain tx, force-refresh the achievements API once (debounced).
    if (!res.simulated && res.hash) {
      this.requestBadgesRefresh();
    }

    if (
      action.kind === 'mineCore.withdrawKingBalance' ||
      action.kind === 'mineCore.withdrawRefundBalance'
    ) {
      const bucket = action.kind === 'mineCore.withdrawKingBalance' ? 'king' : 'refund';
      this.emit('REIGN_REWARD_COLLECTED', 'info', {
        blockNumber: res.receiptBlockNumber,
        txHash: res.hash,
        dedup: `REIGN_REWARD_COLLECTED|${res.hash ?? ''}|${bucket}`,
        data: {
          bucket,
          ethOutWei: action.amount.toString(),
        },
      });
      return;
    }

    if (action.kind === 'claimAllHelper.withdrawKingBalanceForUser') {
      this.emit('REIGN_REWARD_COLLECTED', 'info', {
        blockNumber: res.receiptBlockNumber,
        txHash: res.hash,
        dedup: `REIGN_REWARD_COLLECTED|${res.hash ?? ''}|king|claimAllHelper`,
        data: {
          bucket: 'king',
          user: action.user,
          ethOutWei: action.amount.toString(),
        },
      });
      return;
    }

    if (
      action.kind === 'mineCore.takeover' ||
      action.kind === 'mineCore.takeoverFor' ||
      action.kind === 'mineCore.takeoverWithToken'
    ) {
      const newKing =
        action.kind === 'mineCore.takeoverFor'
          ? action.newKing
          : // mineCore.takeover + mineCore.takeoverWithToken both crown `this.user`.
            this.user;

      const quoted = (res.details as any)?.quoted as any;
      const takeoverPriceWei =
        action.kind === 'mineCore.takeover' || action.kind === 'mineCore.takeoverFor'
          ? action.price.toString()
          : (quoted?.takeoverPrice ?? undefined);

      this.emit('TAKEOVER_SUCCESS', 'info', {
        blockNumber: res.receiptBlockNumber,
        txHash: res.hash,
        dedup: `TAKEOVER_SUCCESS|${res.hash ?? ''}`,
        data: {
          newKing,
          takeoverPriceWei,
          // ETH amount spent is explicit for ETH takeovers; for token takeovers we best-effort
          // report the quoted takeoverPrice (the ETH value MineCore needs).
          ethSpentWei:
            action.kind === 'mineCore.takeover' || action.kind === 'mineCore.takeoverFor'
              ? action.price.toString()
              : takeoverPriceWei,
          tokenIn: action.kind === 'mineCore.takeoverWithToken' ? action.tokenIn : undefined,
          amountIn:
            action.kind === 'mineCore.takeoverWithToken' ? action.amountIn.toString() : undefined,
          source: 'action',
        },
      });
      return;
    }

    if (action.kind === 'furnace.enterWithEth' || action.kind === 'furnace.enterWithEthFor') {
      const ethIn = action.ethIn.toString();

      // Pull quoted details when present (best-effort).
      const quoted = (res.details as any)?.quoted as any;

      this.emit('FURNACE_LOCK_CREATED', 'info', {
        blockNumber: res.receiptBlockNumber,
        txHash: res.hash,
        dedup: `FURNACE_LOCK_CREATED|${res.hash ?? ''}`,
        data: {
          user: action.kind === 'furnace.enterWithEthFor' ? action.user : this.user,
          mode: 'ETH',
          ethInWei: ethIn,
          principalClaimWei: quoted?.principalClaim,
          bonusClaimWei: quoted?.bonusClaim,
          claimInWei:
            quoted?.principalClaim && quoted?.bonusClaim
              ? (BigInt(quoted.principalClaim) + BigInt(quoted.bonusClaim)).toString()
              : undefined,
          bonusBps:
            quoted?.principalClaim && quoted?.bonusClaim
              ? computeBonusBps(
                  BigInt(quoted.principalClaim),
                  BigInt(quoted.bonusClaim),
                )?.toString()
              : undefined,
          veOutWei: quoted?.veOut,
          routeTokenId: quoted?.routeTokenId,
          source: 'action',
        },
      });
    }
  }
}

function scoreAction(action: AgentAction): bigint {
  // Simple, best-effort utility scoring in wei terms.
  // Positive => inflow, Negative => outflow.
  switch (action.kind) {
    case 'royalties.claimShareholderEth':
      return action.claimable;

    case 'mineCore.withdrawKingBalance':
      return action.amount;

    case 'mineCore.withdrawRefundBalance':
      return action.amount;

    case 'claimAllHelper.claimShareholderForUser':
      return action.claimable;

    case 'claimAllHelper.claimAllFor':
      return action.claimable;

    case 'claimAllHelper.withdrawKingBalanceForUser':
      return action.amount;

    case 'mineCore.takeover':
      return -action.price;

    case 'mineCore.takeoverFor':
      return -action.price;

    case 'furnace.enterWithEth':
      return -action.ethIn;

    case 'furnace.enterWithEthFor':
      return -action.ethIn;

    default:
      return 0n;
  }
}
