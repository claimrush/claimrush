import fs from 'node:fs';
import path from 'node:path';

import type { Hash, PublicClient } from 'viem';

import type { ClaimRushEvent } from '../events.js';
import { clampStrictSafeInteger } from '../integers.js';
import { writeTextFileNoFollow } from '../security/fs.js';

const MAX_CURSOR_FILE_BYTES = 1_000_000;
const HARD_MAX_RECENT_KEYS = 100_000;

export type EventCursorParams = {
  filePath: string;
  chainId: number;
  /** How many blocks to rewind on restart / reorg detection. */
  rewindBlocks: bigint;
  /** How many recent (txHash-logIndex) keys to persist for dedupe. */
  maxRecentKeys: number;
};

type PersistedV1 = {
  version: 1;
  chainId: number;
  rewindBlocks: string;
  lastProcessedBlock?: string;
  lastProcessedBlockHash?: Hash;
  recentKeys: string[];
};

type InMemoryV1 = {
  version: 1;
  chainId: number;
  rewindBlocks: bigint;
  maxRecentKeys: number;
  lastProcessedBlock?: bigint;
  lastProcessedBlockHash?: Hash;
  recentKeys: string[];
  recentSet: Set<string>;
};

function parseBigintOrUndefined(v: unknown): bigint | undefined {
  if (typeof v !== 'string') return undefined;
  if (!/^[0-9]+$/.test(v)) return undefined;
  try {
    return BigInt(v);
  } catch {
    return undefined;
  }
}

function ensureDirForFile(filePath: string): void {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}

function keyForEvent(ev: ClaimRushEvent): string {
  // Prefer subgraph entity id when available (it usually encodes txHash-logIndex already).
  if (ev.source === 'subgraph' && ev.subgraphId) return `subgraph:${ev.subgraphId}`;
  return `${ev.transactionHash}-${ev.logIndex}`;
}

export class EventCursor {
  private readonly filePath: string;
  private s: InMemoryV1;

  private constructor(filePath: string, state: InMemoryV1) {
    this.filePath = filePath;
    this.s = state;
  }

  static load(params: EventCursorParams): EventCursor {
    ensureDirForFile(params.filePath);

    const raw = EventCursor.readFile(params.filePath);

    // Start clean by default.
    const rewindBlocks = params.rewindBlocks < 0n ? 0n : params.rewindBlocks;
    // Fail-closed: fractional or otherwise malformed values fall back to the
    // default rather than silently truncating (e.g. 1.5 → 1).
    const maxRecentKeys = clampStrictSafeInteger(
      params.maxRecentKeys,
      5_000,
      0,
      HARD_MAX_RECENT_KEYS,
    );

    const base: InMemoryV1 = {
      version: 1,
      chainId: params.chainId,
      rewindBlocks,
      maxRecentKeys,
      lastProcessedBlock: undefined,
      lastProcessedBlockHash: undefined,
      recentKeys: [],
      recentSet: new Set(),
    };

    if (!raw) return new EventCursor(params.filePath, base);

    // Ignore if chainId mismatches.
    if (raw.chainId !== params.chainId) {
      return new EventCursor(params.filePath, base);
    }

    const lastProcessedBlock = parseBigintOrUndefined(raw.lastProcessedBlock);

    const recentKeys = Array.isArray(raw.recentKeys)
      ? raw.recentKeys.filter((x): x is string => typeof x === 'string' && x.length > 0)
      : [];

    // Respect current caps.
    const capped = recentKeys.slice(Math.max(0, recentKeys.length - base.maxRecentKeys));

    return new EventCursor(params.filePath, {
      ...base,
      lastProcessedBlock,
      lastProcessedBlockHash: raw.lastProcessedBlockHash,
      recentKeys: capped,
      recentSet: new Set(capped),
    });
  }

  /** Current durable checkpoint. */
  snapshot(): {
    chainId: number;
    rewindBlocks: bigint;
    lastProcessedBlock?: bigint;
    lastProcessedBlockHash?: Hash;
    recentKeyCount: number;
  } {
    return {
      chainId: this.s.chainId,
      rewindBlocks: this.s.rewindBlocks,
      lastProcessedBlock: this.s.lastProcessedBlock,
      lastProcessedBlockHash: this.s.lastProcessedBlockHash,
      recentKeyCount: this.s.recentKeys.length,
    };
  }

  /**
   * Start block for the next stream.
   * - If no checkpoint exists: undefined (stream decides how to start)
   * - Otherwise: lastProcessedBlock - rewindBlocks (floored at 0)
   */
  getStartBlock(): bigint | undefined {
    const last = this.s.lastProcessedBlock;
    if (typeof last !== 'bigint') return undefined;
    const rb = this.s.rewindBlocks;
    const start = last > rb ? last - rb : 0n;
    return start;
  }

  /** De-dupe events within the rollback window. */
  shouldProcess(ev: ClaimRushEvent): boolean {
    const key = keyForEvent(ev);
    return !this.s.recentSet.has(key);
  }

  /**
   * Record an event as processed.
   * - maintains a capped de-dupe key ring
   * - updates lastProcessedBlock/hash when higher blocks are seen
   */
  async recordProcessedEvent(ev: ClaimRushEvent, publicClient: PublicClient): Promise<void> {
    const key = keyForEvent(ev);

    if (!this.s.recentSet.has(key)) {
      this.s.recentKeys.push(key);
      this.s.recentSet.add(key);

      while (this.s.recentKeys.length > this.s.maxRecentKeys) {
        const oldest = this.s.recentKeys.shift();
        if (oldest) this.s.recentSet.delete(oldest);
      }
    }

    const last = this.s.lastProcessedBlock;
    if (typeof last !== 'bigint' || ev.blockNumber > last) {
      this.s.lastProcessedBlock = ev.blockNumber;

      // Best-effort: store the block hash so we can detect reorgs across restarts.
      try {
        const blk = await publicClient.getBlock({ blockNumber: ev.blockNumber });
        this.s.lastProcessedBlockHash = blk.hash as Hash;
      } catch {
        // ignore
      }
    }

    this.persist();
  }

  /**
   * On restart, validate the last processed block hash against the chain.
   * If a mismatch is detected, rewind deeper + clear recent keys.
   */
  async validateAgainstChain(
    publicClient: PublicClient,
  ): Promise<{ ok: boolean; rewoundFrom?: bigint }> {
    const last = this.s.lastProcessedBlock;
    const hash = this.s.lastProcessedBlockHash;
    if (typeof last !== 'bigint' || !hash) return { ok: true };

    try {
      const blk = await publicClient.getBlock({ blockNumber: last });
      const got = blk.hash as Hash;
      if (got === hash) return { ok: true };

      const rewoundFrom = last;
      this.rewind();
      this.persist();
      return { ok: false, rewoundFrom };
    } catch {
      // If the block is not available / pruned, be conservative and rewind.
      const rewoundFrom = last;
      this.rewind();
      this.persist();
      return { ok: false, rewoundFrom };
    }
  }

  private rewind(): void {
    const last = this.s.lastProcessedBlock;
    if (typeof last !== 'bigint') {
      this.s.recentKeys = [];
      this.s.recentSet = new Set();
      this.s.lastProcessedBlockHash = undefined;
      return;
    }

    const rb = this.s.rewindBlocks;
    const next = last > rb ? last - rb : 0n;

    this.s.lastProcessedBlock = next;
    this.s.lastProcessedBlockHash = undefined;
    this.s.recentKeys = [];
    this.s.recentSet = new Set();
  }

  private persist(): void {
    const out: PersistedV1 = {
      version: 1,
      chainId: this.s.chainId,
      rewindBlocks: this.s.rewindBlocks.toString(),
      lastProcessedBlock: this.s.lastProcessedBlock?.toString(),
      lastProcessedBlockHash: this.s.lastProcessedBlockHash,
      recentKeys: this.s.recentKeys,
    };

    ensureDirForFile(this.filePath);
    writeTextFileNoFollow(this.filePath, JSON.stringify(out, null, 2) + '\n', {
      encoding: 'utf8',
      mode: 0o600,
    });
  }

  private static readFile(filePath: string): PersistedV1 | undefined {
    try {
      if (!fs.existsSync(filePath)) return undefined;
      const st = fs.statSync(filePath);
      if (!st.isFile()) return undefined;
      if (st.size > MAX_CURSOR_FILE_BYTES) return undefined;
      const raw = fs.readFileSync(filePath, 'utf8');
      const parsed = JSON.parse(raw) as any;
      if (!parsed || parsed.version !== 1) return undefined;
      // Reject malformed persisted chainId (wrong type, fractional number,
      // etc). Falling back to undefined discards the stale checkpoint so
      // callers restart from a fresh cursor instead of misinterpreting state
      // from a different chain or a partially corrupted file.
      if (!Number.isInteger(parsed.chainId)) return undefined;
      if (!Array.isArray(parsed.recentKeys)) return undefined;
      return parsed as PersistedV1;
    } catch {
      return undefined;
    }
  }
}
