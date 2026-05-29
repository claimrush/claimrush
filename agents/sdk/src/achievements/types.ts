import type { Address, Hash } from 'viem';

export type AchievementKind =
  | 'TAKEOVER_SUCCESS'
  | 'BACKOFF_ENTERED'
  | 'BACKOFF_CLEARED'
  | 'REIGN_REWARD_COLLECTED'
  | 'FURNACE_LOCK_CREATED'
  | 'ROYALTIES_CLAIMED'
  | 'AUTOCOMPOUND_EXECUTED'
  | 'BADGE_UNLOCKED'
  | 'SLIPPAGE_GUARD_TRIGGERED'
  | 'SESSION_EXPIRED'
  | 'PAUSED_ACTION_SKIPPED'
  | 'REVERTED_TX'
  | 'RPC_LAG_DETECTED'
  | 'SUBGRAPH_LAG_DETECTED'
  | 'ACTION_UTILITY';

export type AchievementLevel = 'info' | 'warn' | 'error';

/**
 * Structured milestone / incident emitted by the agent runtime.
 *
 * Intended uses:
 * - compact telemetry for dashboards and logs
 * - lightweight reward shaping signals for agent policy training
 */
export type Achievement = {
  /** Milliseconds since unix epoch. */
  ts: number;

  kind: AchievementKind;
  level: AchievementLevel;

  chain?: string;
  chainId?: number;
  agent?: Address;
  /** Identity being managed (same as agent when self-playing). */
  user?: Address;

  blockNumber?: bigint;
  blockTimestamp?: bigint;

  txHash?: Hash;

  /** Arbitrary, versioned payload for this achievement kind. */
  data?: Record<string, unknown>;
};

export type AchievementWriter = (a: Achievement) => void;
