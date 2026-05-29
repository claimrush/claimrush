/**
 * Heuristic timezone detection from on-chain activity patterns.
 *
 * Analyses a user's transaction timestamps to find their "quiet gap" (night),
 * then schedules daily rewards for right after that gap ends (morning).
 *
 * The algorithm:
 *   1. Fetch the last ~50 ActivityItem timestamps per user from the subgraph.
 *   2. Bucket into a 24-slot histogram (hours 0–23 UTC).
 *   3. Find the longest contiguous run of empty/low-activity slots (night).
 *   4. morningHourUtc = the hour immediately after that run.
 *
 * Users with fewer than MIN_EVENTS events get morningHourUtc = null (processed
 * on any eligible run — same as before this feature).
 */

import { querySubgraph } from './subgraph.js';
import { loadJson, saveJsonAtomic } from './state.js';
import { parseNonNegativeSafeInteger } from './utils.js';

const MIN_EVENTS = 10;
const EVENTS_PER_USER = 50;
const REFRESH_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000; // 1 week
const BATCH_SIZE = 100; // users per subgraph query batch

// ---- Public types ----

export interface MorningCache {
  version: number;
  refreshedAtMs: number;
  users: Record<string, number | null>; // address → morningHourUtc (0–23) or null
}

// ---- Night-gap algorithm ----

/**
 * Given an array of unix timestamps (seconds), detect the hour-of-day (UTC)
 * that best represents the user's "morning" — i.e. the end of their longest
 * quiet period.
 *
 * Returns null if there are fewer than MIN_EVENTS timestamps or no clear gap.
 */
export function detectMorningHour(timestamps: number[]): number | null {
  if (timestamps.length < MIN_EVENTS) return null;

  const histogram = new Array<number>(24).fill(0);
  for (const ts of timestamps) {
    const hour = Math.floor((ts % 86_400) / 3_600);
    histogram[hour]++;
  }

  const totalEvents = timestamps.length;
  // "low activity" threshold: a slot is quiet if it has <= 5% of total events
  const lowThreshold = Math.max(1, Math.floor(totalEvents * 0.05));

  // Find the longest contiguous run of low-activity hours (wrapping around midnight)
  let bestStart = -1;
  let bestLen = 0;

  for (let start = 0; start < 24; start++) {
    let len = 0;
    for (let offset = 0; offset < 24; offset++) {
      const h = (start + offset) % 24;
      if (histogram[h] < lowThreshold) {
        len++;
      } else {
        break;
      }
    }
    if (len > bestLen) {
      bestLen = len;
      bestStart = start;
    }
  }

  // Need at least a 4-hour quiet gap to be meaningful
  if (bestLen < 4 || bestStart < 0) return null;

  // Morning = the hour right after the quiet gap ends
  const morningHour = (bestStart + bestLen) % 24;
  return morningHour;
}

// ---- Subgraph queries ----

const ACTIVE_USERS_QUERY = `
  query ActiveUsers($first: Int!, $skip: Int!) {
    activityItems(
      orderBy: timestamp
      orderDirection: desc
      first: $first
      skip: $skip
    ) {
      user { id }
    }
  }
`;

interface ActiveUsersResult {
  activityItems: Array<{ user: { id: string } | null }>;
}

/**
 * Fetch unique user addresses from recent activity. Used to discover which
 * users to profile when no explicit user list is provided.
 */
export async function fetchActiveUsers(subgraphUrl: string, maxUsers = 500): Promise<string[]> {
  const seen = new Set<string>();
  let skip = 0;
  const pageSize = 1000;

  while (seen.size < maxUsers && skip < 5000) {
    try {
      const data = await querySubgraph<ActiveUsersResult>(subgraphUrl, ACTIVE_USERS_QUERY, {
        first: pageSize,
        skip,
      });
      const items = data.activityItems ?? [];
      if (!items.length) break;
      for (const item of items) {
        if (item.user?.id) seen.add(item.user.id.toLowerCase());
        if (seen.size >= maxUsers) break;
      }
      skip += pageSize;
    } catch {
      break;
    }
  }

  return Array.from(seen);
}

const ACTIVITY_QUERY = `
  query UserActivity($userId: ID!, $first: Int!) {
    activityItems(
      where: { user: $userId }
      orderBy: timestamp
      orderDirection: desc
      first: $first
    ) {
      timestamp
    }
  }
`;

interface ActivityQueryResult {
  activityItems: Array<{ timestamp: string }>;
}

export function normalizeActivityTimestamps(
  items: Array<{ timestamp: string }> | null | undefined,
): number[] {
  const out: number[] = [];
  for (const item of items ?? []) {
    const parsed = parseNonNegativeSafeInteger(item?.timestamp, { defaultValue: null });
    if (parsed != null) out.push(parsed);
  }
  return out;
}

async function fetchUserTimestamps(subgraphUrl: string, userAddress: string): Promise<number[]> {
  const userId = userAddress.toLowerCase();
  const data = await querySubgraph<ActivityQueryResult>(subgraphUrl, ACTIVITY_QUERY, {
    userId,
    first: EVENTS_PER_USER,
  });
  return normalizeActivityTimestamps(data.activityItems);
}

// ---- Cache management ----

function initCache(): MorningCache {
  return { version: 1, refreshedAtMs: 0, users: {} };
}

export function loadMorningCache(cachePath: string): MorningCache {
  const raw = loadJson(cachePath, { fallback: null }) as Record<string, unknown> | null;
  if (!raw || typeof raw !== 'object') return initCache();

  const cache = initCache();
  if (typeof raw.refreshedAtMs === 'number') cache.refreshedAtMs = raw.refreshedAtMs;
  if (raw.users && typeof raw.users === 'object' && !Array.isArray(raw.users)) {
    cache.users = raw.users as Record<string, number | null>;
  }
  return cache;
}

export function saveMorningCache(cachePath: string, cache: MorningCache): void {
  saveJsonAtomic(cachePath, cache);
}

// ---- Refresh logic ----

/**
 * Refresh the morning cache for a set of users. Only re-queries if the cache
 * is older than REFRESH_INTERVAL_MS.
 *
 * @returns The (possibly updated) cache.
 */
export async function refreshMorningCache(args: {
  cachePath: string;
  subgraphUrl: string;
  users: string[];
  log: (msg: string) => void;
  forceRefresh?: boolean;
}): Promise<MorningCache> {
  const { cachePath, subgraphUrl, log, forceRefresh } = args;
  let { users } = args;
  const cache = loadMorningCache(cachePath);

  const age = Date.now() - cache.refreshedAtMs;
  if (!forceRefresh && age < REFRESH_INTERVAL_MS && Object.keys(cache.users).length > 0) {
    return cache;
  }

  if (!users.length) {
    try {
      users = await fetchActiveUsers(subgraphUrl);
      log(`morning-detect: discovered ${users.length} active users from subgraph`);
    } catch (e: unknown) {
      log(`morning-detect: failed to discover users: ${e}`);
      return cache;
    }
  }

  if (!users.length) return cache;

  log(`morning-detect: refreshing timezone data for ${users.length} users`);

  let updated = 0;
  let failed = 0;

  for (let i = 0; i < users.length; i += BATCH_SIZE) {
    const batch = users.slice(i, i + BATCH_SIZE);

    for (const user of batch) {
      try {
        const timestamps = await fetchUserTimestamps(subgraphUrl, user);
        const morning = detectMorningHour(timestamps);
        cache.users[user.toLowerCase()] = morning;
        updated++;
      } catch {
        failed++;
      }
    }
  }

  cache.refreshedAtMs = Date.now();
  saveMorningCache(cachePath, cache);

  const detected = Object.values(cache.users).filter((v) => v !== null).length;
  log(
    `morning-detect: refreshed ${updated} users (${failed} failed). ${detected}/${Object.keys(cache.users).length} have detected mornings`,
  );

  return cache;
}

// ---- Filtering helper ----

/**
 * Check if a user is currently in their morning window.
 *
 * @param cache        The loaded morning cache.
 * @param userAddress  The user's address (any case).
 * @param windowHours  Half-width of the window (e.g. 1 means ±1h = 3h total).
 * @returns true if user should be processed now, false to defer.
 *          Users without a detected morning always return true (fallback).
 */
export function isInMorningWindow(
  cache: MorningCache,
  userAddress: string,
  windowHours: number,
): boolean {
  const morning = cache.users[userAddress.toLowerCase()];
  if (morning == null) return true; // no data — process anytime

  const currentHourUtc = new Date().getUTCHours();
  const diff = Math.abs(currentHourUtc - morning);
  // Handle wraparound (e.g. morning=23, current=1 → diff should be 2, not 22)
  const circularDiff = Math.min(diff, 24 - diff);
  return circularDiff <= windowHours;
}
