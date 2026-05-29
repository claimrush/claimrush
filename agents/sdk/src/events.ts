// Event streaming helpers: polling + WebSocket transports with optional
// subgraph backfill.
//
// De-duplication uses `(blockNumber, txHash, logIndex)` as the key. Callers
// that replay from a backfill source without a stable `logIndex` should supply
// their own ordering key to avoid collapsing distinct events in the same tx.
// The per-block timestamp cache is intentionally unbounded for the lifetime of
// a short-lived agent run; long-running consumers should cap retention via
// their own bounded cache.

import type { Abi, Address, Hash, PublicClient } from 'viem';
import type { AbiNetwork } from './abis.js';
import { loadAbi } from './abis.js';
import type { DeploymentManifest } from './manifest.js';
import {
  SubgraphClient,
  getRecentFurnaceEnters,
  getRecentShareholderAutoCompounds,
  getRecentShareholderClaims,
  getRecentTakeovers,
} from './subgraph.js';

import { DEFAULT_PUBLIC_HTTP_URL_POLICY, type OutboundUrlPolicy } from './security/url.js';

export type ClaimRushEvent = {
  /** Contract key from manifest (e.g. MineCore, Furnace). */
  contract: string;
  /** Log address (should equal the contract address). */
  address: Address;
  /** Event name (e.g. Takeover). */
  event: string;
  /** Decoded event args as a plain object. */
  args: Record<string, unknown>;
  blockNumber: bigint;
  transactionHash: Hash;
  logIndex: number;
  /** Optional block timestamp (seconds). */
  blockTimestamp?: bigint;

  /**
   * Where this event came from.
   * - rpc: decoded directly from onchain logs (viem)
   * - subgraph: reconstructed from subgraph entities (+ optional receipt lookups)
   */
  source?: 'rpc' | 'subgraph';

  /** If source=subgraph, the entity id (usually txHash-logIndex). */
  subgraphId?: string;
};

export type ClaimRushEventStreamOptions = {
  publicClient: PublicClient;
  manifest: DeploymentManifest;
  /** Which ABI folder to read from. Default: base_sepolia. */
  abiNetwork?: AbiNetwork;

  /** Contract keys to watch. Defaults to core gameplay contracts. */
  contracts?: string[];

  /** Event names to watch. Defaults to core gameplay events. Use ['*'] to watch all. */
  events?: string[];

  /**
   * Starting block.
   * - undefined: start from current head (best effort)
   * - 'manifest': use each contract's `startBlock` from the manifest
   * - bigint: explicit start block
   */
  fromBlock?: bigint | 'manifest';

  /** If true, fetch and attach block timestamps (cached per block). Default: true. */
  includeBlockTimestamp?: boolean;

  /** Force polling mode (HTTP-friendly). Default: false. */
  poll?: boolean;

  /** Polling interval (ms) when poll=true. Default: 2_000. */
  pollingInterval?: number;

  /**
   * Optional subgraph GraphQL endpoint used to emit a best-effort backfill of recent events
   * before streaming live logs. This does NOT change protocol behavior.
   */
  subgraphUrl?: string;

  /** Optional outbound URL policy for the subgraph backfill query. */
  subgraphNetworkPolicy?: OutboundUrlPolicy;

  /** If true, emit a subgraph backfill before streaming. Default: false. */
  backfillFromSubgraph?: boolean;

  /** Max events per event type to fetch from the subgraph. Default: 100. */
  backfillLimit?: number;

  /** Callback invoked for every decoded event. */
  onEvent: (ev: ClaimRushEvent) => void | Promise<void>;

  /** Optional error callback (otherwise errors are thrown). */
  onError?: (err: unknown) => void;
};

export type ClaimRushEventStreamHandle = {
  stop: () => void;
};

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address;

function abiHasEvent(abi: Abi, eventName: string): boolean {
  return abi.some(
    (item) => item.type === 'event' && 'name' in item && (item as any).name === eventName,
  );
}

function splitCsv(input: string | undefined): string[] | undefined {
  if (!input) return undefined;
  const parts = input
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return parts.length ? parts : undefined;
}

function parseSubgraphLogIndex(entityId: string): number {
  const parts = entityId.split('-');
  if (parts.length < 2) return -1;
  const last = parts[parts.length - 1];
  const n = Number(last);
  return Number.isFinite(n) ? n : -1;
}

function clampFiniteInt(value: unknown, fallback: number, min: number, max: number): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.floor(n);
  if (i < min) return min;
  if (i > max) return max;
  return i;
}

async function getReceiptBlockNumber(
  publicClient: PublicClient,
  hash: Hash,
): Promise<bigint | null> {
  try {
    const receipt = await publicClient.getTransactionReceipt({ hash });
    return receipt.blockNumber;
  } catch {
    return null;
  }
}

export function stringifyJson(value: unknown, opts?: { pretty?: boolean }): string {
  const space = opts?.pretty ? 2 : undefined;
  return JSON.stringify(
    value,
    (_k, v) => {
      if (typeof v === 'bigint') return v.toString();
      return v;
    },
    space,
  );
}

async function emitBackfillFromSubgraph(params: {
  publicClient: PublicClient;
  manifest: DeploymentManifest;
  contracts: string[];
  events: string[];
  watchAll: boolean;
  subgraphUrl: string;
  subgraphNetworkPolicy?: OutboundUrlPolicy;
  backfillLimit: number;
  onEvent: (ev: ClaimRushEvent) => void | Promise<void>;
  onError?: (err: unknown) => void;
  blockTsCache: Map<bigint, bigint>;
  dedupKeys: Set<string>;
}): Promise<void> {
  const wantEvent = (name: string): boolean => params.watchAll || params.events.includes(name);
  const wantContract = (name: string): boolean => params.contracts.includes(name);

  const mineCoreAddr = (params.manifest.contracts as any)?.MineCore?.address as Address | undefined;
  const furnaceAddr = (params.manifest.contracts as any)?.Furnace?.address as Address | undefined;
  const royaltiesAddr = (params.manifest.contracts as any)?.ShareholderRoyalties?.address as
    | Address
    | undefined;

  const client = new SubgraphClient({
    url: params.subgraphUrl,
    networkPolicy: params.subgraphNetworkPolicy,
  });

  const out: ClaimRushEvent[] = [];

  // 1) Takeover (has blockNumber + timestamp)
  if (mineCoreAddr && wantContract('MineCore') && wantEvent('Takeover')) {
    try {
      const rows = await getRecentTakeovers(client, params.backfillLimit);
      for (const row of rows) {
        const blockNumber = BigInt(row.blockNumber);
        const ts = BigInt(row.timestamp);
        const logIndex = parseSubgraphLogIndex(row.id);
        const txHash = row.txHash as Hash;

        const reignId = BigInt(row.reign.reignId);
        const previousKing = (row.previousKing?.id ?? ZERO_ADDRESS) as Address;
        const newKing = row.newKing.id as Address;

        out.push({
          source: 'subgraph',
          subgraphId: row.id,
          contract: 'MineCore',
          address: mineCoreAddr,
          event: 'Takeover',
          args: {
            reignId,
            previousKing,
            newKing,
            pricePaid: BigInt(row.pricePaidWei),
            referencePrice: BigInt(row.referencePriceWei),
            timestamp: ts,
          },
          blockNumber,
          transactionHash: txHash,
          logIndex,
          blockTimestamp: ts,
        });

        params.blockTsCache.set(blockNumber, ts);
      }
    } catch (err) {
      if (params.onError) params.onError(err);
    }
  }

  // 2) FurnaceEnter (has blockNumber + timestamp)
  if (furnaceAddr && wantContract('Furnace') && wantEvent('FurnaceEnter')) {
    try {
      const rows = await getRecentFurnaceEnters(client, params.backfillLimit);
      for (const row of rows) {
        const user = (row.user?.id ?? ZERO_ADDRESS) as Address;
        const blockNumber = BigInt(row.blockNumber);
        const ts = BigInt(row.timestamp);
        const logIndex = parseSubgraphLogIndex(row.id);
        const txHash = row.txHash as Hash;

        out.push({
          source: 'subgraph',
          subgraphId: row.id,
          contract: 'Furnace',
          address: furnaceAddr,
          event: 'FurnaceEnter',
          args: {
            user,
            mode: BigInt(row.mode),
            ethIn: BigInt(row.ethInWei),
            principalClaim: BigInt(row.principalClaimWei),
            bonusClaim: BigInt(row.bonusClaimWei),
            tokenId: BigInt(row.tokenId),
          },
          blockNumber,
          transactionHash: txHash,
          logIndex,
          blockTimestamp: ts,
        });

        params.blockTsCache.set(blockNumber, ts);
      }
    } catch (err) {
      if (params.onError) params.onError(err);
    }
  }

  // 3) ShareholderClaim (no blockNumber; fill from receipt)
  if (royaltiesAddr && wantContract('ShareholderRoyalties') && wantEvent('ShareholderClaim')) {
    try {
      const rows = await getRecentShareholderClaims(client, params.backfillLimit);
      for (const row of rows) {
        const txHash = row.txHash as Hash;
        const blockNumber = await getReceiptBlockNumber(params.publicClient, txHash);
        if (blockNumber === null) continue;

        const ts = BigInt(row.timestamp);
        const logIndex = parseSubgraphLogIndex(row.id);
        const user = (row.user?.id ?? ZERO_ADDRESS) as Address;

        out.push({
          source: 'subgraph',
          subgraphId: row.id,
          contract: 'ShareholderRoyalties',
          address: royaltiesAddr,
          event: 'ShareholderClaim',
          args: {
            user,
            mode: BigInt(row.mode),
            amountEth: BigInt(row.amountEthWei),
          },
          blockNumber,
          transactionHash: txHash,
          logIndex,
          blockTimestamp: ts,
        });

        params.blockTsCache.set(blockNumber, ts);
      }
    } catch (err) {
      if (params.onError) params.onError(err);
    }
  }

  // 4) ShareholderAutoCompoundExecuted (no blockNumber; fill from receipt)
  if (
    royaltiesAddr &&
    wantContract('ShareholderRoyalties') &&
    wantEvent('ShareholderAutoCompoundExecuted')
  ) {
    try {
      const rows = await getRecentShareholderAutoCompounds(client, params.backfillLimit);
      for (const row of rows) {
        const txHash = row.txHash as Hash;
        const blockNumber = await getReceiptBlockNumber(params.publicClient, txHash);
        if (blockNumber === null) continue;

        const ts = BigInt(row.timestamp);
        const logIndex = parseSubgraphLogIndex(row.id);
        const user = (row.user?.id ?? ZERO_ADDRESS) as Address;
        const executor = (row.executor?.id ?? ZERO_ADDRESS) as Address;

        out.push({
          source: 'subgraph',
          subgraphId: row.id,
          contract: 'ShareholderRoyalties',
          address: royaltiesAddr,
          event: 'ShareholderAutoCompoundExecuted',
          args: {
            user,
            executor,
            amountEth: BigInt(row.amountEthWei),
            tokenId: BigInt(row.tokenId),
            effectiveDurationSeconds: BigInt(row.effectiveDurationSeconds),
          },
          blockNumber,
          transactionHash: txHash,
          logIndex,
          blockTimestamp: ts,
        });

        params.blockTsCache.set(blockNumber, ts);
      }
    } catch (err) {
      if (params.onError) params.onError(err);
    }
  }

  if (!out.length) return;

  // Sort ascending (so replay feels natural)
  out.sort((a, b) => {
    if (a.blockNumber < b.blockNumber) return -1;
    if (a.blockNumber > b.blockNumber) return 1;
    if (a.logIndex !== b.logIndex) return a.logIndex - b.logIndex;
    const evCmp = a.event.localeCompare(b.event);
    if (evCmp !== 0) return evCmp;
    return (a.subgraphId ?? '').localeCompare(b.subgraphId ?? '');
  });

  // De-dupe (shared with live watcher via params.dedupKeys)
  for (const ev of out) {
    const key = `${ev.transactionHash}:${ev.logIndex}:${ev.contract}:${ev.event}:${ev.subgraphId ?? ''}`;
    if (params.dedupKeys.has(key)) continue;
    params.dedupKeys.add(key);
    try {
      await params.onEvent(ev);
    } catch (err) {
      if (params.onError) params.onError(err);
      else throw err;
    }
  }
}

export async function startClaimRushEventStream(
  opts: ClaimRushEventStreamOptions,
): Promise<ClaimRushEventStreamHandle> {
  const abiNetwork = opts.abiNetwork ?? 'base_sepolia';
  const includeBlockTimestamp = opts.includeBlockTimestamp ?? true;
  const poll = opts.poll ?? false;
  const pollingInterval = clampFiniteInt(opts.pollingInterval ?? 2_000, 2_000, 100, 60_000);

  const backfillFromSubgraph = opts.backfillFromSubgraph ?? false;
  const backfillLimit = clampFiniteInt(opts.backfillLimit ?? 100, 100, 0, 5_000);

  const contracts = opts.contracts ??
    // “Core” by default
    [
      'MineCore',
      'Furnace',
      'ShareholderRoyalties',
      'MaintenanceHub',
      'MarketRouter',
      'LpStakingVault7D',
      'VeClaimNFT',
    ];

  const events = opts.events ?? [
    // “Core” by default
    'Takeover',
    'FurnaceEnter',
    'ShareholderClaim',
    'ShareholderAutoCompoundExecuted',
    'Poked',
  ];

  const watchAll = events.includes('*');

  // If fromBlock is not specified, best effort: start from current head.
  // This avoids replaying historical logs by default.
  const headBlock =
    opts.fromBlock === undefined ? await opts.publicClient.getBlockNumber() : undefined;

  const MAX_BLOCK_TS_CACHE = 10_000;
  const blockTsCache = new Map<bigint, bigint>();
  const dedupKeys = new Set<string>();

  const onError = opts.onError;

  const chainId = await opts.publicClient.getChainId().catch(() => undefined);
  const subgraphNetworkPolicy =
    opts.subgraphNetworkPolicy ?? (chainId === 31337 ? undefined : DEFAULT_PUBLIC_HTTP_URL_POLICY);

  // Optional: emit a recent-history backfill from the subgraph.
  if (backfillFromSubgraph && opts.subgraphUrl) {
    await emitBackfillFromSubgraph({
      publicClient: opts.publicClient,
      manifest: opts.manifest,
      contracts,
      events,
      watchAll,
      subgraphUrl: opts.subgraphUrl,
      subgraphNetworkPolicy,
      backfillLimit,
      onEvent: opts.onEvent,
      onError,
      blockTsCache,
      dedupKeys,
    });
  }

  const unwatchFns: Array<() => void> = [];

  async function attachTimestampIfNeeded(blockNumber: bigint): Promise<bigint | undefined> {
    if (!includeBlockTimestamp) return undefined;
    const cached = blockTsCache.get(blockNumber);
    if (cached !== undefined) return cached;
    const block = await opts.publicClient.getBlock({ blockNumber });
    const ts = block.timestamp;
    blockTsCache.set(blockNumber, ts);
    while (blockTsCache.size > MAX_BLOCK_TS_CACHE) {
      const k = blockTsCache.keys().next().value as bigint | undefined;
      if (k === undefined) break;
      blockTsCache.delete(k);
    }
    return ts;
  }

  for (const contractName of contracts) {
    const ref = (opts.manifest.contracts as any)?.[contractName];
    if (!ref?.address) continue;
    const address = ref.address as Address;
    const abi = loadAbi({ contractName, abiNetwork });

    const fromBlock: bigint | undefined =
      opts.fromBlock === 'manifest'
        ? BigInt(ref.startBlock ?? 0)
        : opts.fromBlock === undefined
          ? headBlock
          : opts.fromBlock;

    // If the user specified explicit events, register one watcher per event (if present in ABI).
    // This keeps logs small and avoids decoding everything.
    const eventNames = watchAll
      ? [null]
      : events
          .filter((ev) => abiHasEvent(abi, ev))
          // de-dupe
          .filter((ev, i, arr) => arr.indexOf(ev) === i);

    for (const eventName of eventNames) {
      const params: any = {
        address,
        abi,
        fromBlock,
        poll,
        pollingInterval,
        onLogs: async (logs: any[]) => {
          for (const log of logs as any[]) {
            try {
              const evName = (log.eventName ?? eventName ?? 'Unknown') as string;
              if (!watchAll && !events.includes(evName)) continue;

              const blockNumber = log.blockNumber as bigint | undefined;
              const transactionHash = log.transactionHash as Hash | undefined;
              const logIndex = Number(log.logIndex ?? 0);

              // Some transports can emit logs without these fields; skip those.
              if (!blockNumber || !transactionHash) continue;

              const liveKey = `${transactionHash}:${logIndex}:${contractName}:${evName}:`;
              if (dedupKeys.has(liveKey)) continue;
              dedupKeys.add(liveKey);
              if (dedupKeys.size > 50_000) {
                // Evict oldest ~25% instead of clearing everything.
                // clear() would nuke all dedup state, causing previously-seen
                // events to pass through again if re-encountered during
                // chain reorgs or polling overlap.
                const iter = dedupKeys.values();
                const evictCount = Math.floor(dedupKeys.size * 0.25);
                for (let ei = 0; ei < evictCount; ei++) {
                  const v = iter.next().value;
                  if (v !== undefined) dedupKeys.delete(v);
                }
              }

              const blockTimestamp = await attachTimestampIfNeeded(blockNumber);
              const args = (log.args ?? {}) as Record<string, unknown>;

              await opts.onEvent({
                source: 'rpc',
                contract: contractName,
                address,
                event: evName,
                args,
                blockNumber,
                transactionHash,
                logIndex,
                blockTimestamp,
              });
            } catch (err) {
              if (onError) onError(err);
              else throw err;
            }
          }
        },
        onError: (err: Error) => {
          if (onError) onError(err);
          else throw err;
        },
      };

      // Only include eventName when filtering. (When omitted, viem watches all events.)
      if (eventName) params.eventName = eventName;
      const unwatch = opts.publicClient.watchContractEvent(params);

      unwatchFns.push(unwatch);
    }
  }

  return {
    stop: () => {
      for (const unwatch of unwatchFns) {
        try {
          unwatch();
        } catch {
          // ignore
        }
      }
    },
  };
}

/**
 * Convenience parser for CLI users.
 *
 * Example:
 * - CONTRACTS=MineCore,Furnace
 * - EVENTS=Takeover,FurnaceEnter
 */
export function parseEventStreamEnv(env: NodeJS.ProcessEnv): {
  contracts?: string[];
  events?: string[];
} {
  return {
    contracts: splitCsv(env.CONTRACTS),
    events: splitCsv(env.EVENTS),
  };
}
