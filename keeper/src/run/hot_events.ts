/**
 * Single source of truth for the log filters that drive the keeper's
 * event-driven hot tasks (phase 4c).
 *
 * Rationale for keeping these here instead of inside each task file:
 *
 * - Every event signature also appears inside the task that polls for it
 *   (via `parseAbiItem(...)`), but those lives are load-bearing for the
 *   task's own decode logic.  Duplicating them here as viem selectors
 *   decouples the WS subscription set from any future refactor of
 *   individual task files — we never want a well-intentioned rename in
 *   `market_discovery.ts` to silently stop poking `sweep-market`.
 *
 * - Phase 4e also wants to merge these into a single `eth_getLogs` call
 *   per safety-net pass.  Having one table to project over makes that
 *   merge a short reduce instead of chasing imports across files.
 */

import { getEventSelector, parseAbiItem, type AbiEvent, type Address } from 'viem';

import type { DeploymentManifest } from '../shared/deployments.js';
import { getContractAddress } from '../shared/deployments.js';
import type { LogFilter } from './event_bus.js';

interface HotEventSpec {
  taskName: string;
  contractKey: string;
  eventSignature: string;
  label: string;
}

const HOT_EVENT_SPECS: readonly HotEventSpec[] = [
  {
    taskName: 'poke',
    contractKey: 'MineCore',
    eventSignature:
      'event Takeover(uint256 indexed reignId, address indexed previousKing, address indexed newKing, uint256 pricePaid, uint256 referencePrice, uint256 reignDuration)',
    label: 'MineCore.Takeover',
  },
  // Market offers: any lifecycle change invalidates the sweep-market
  // discovery set, so Configured + Cancelled both trigger sweep-market.
  {
    taskName: 'sweep-market',
    contractKey: 'MarketRouter',
    eventSignature:
      'event BonusTargetEscrowConfigured(uint256 indexed offerId, address indexed buyer, uint256 targetBonusBps, uint256 slippageBps)',
    label: 'MarketRouter.BonusTargetEscrowConfigured',
  },
  {
    taskName: 'sweep-market',
    contractKey: 'MarketRouter',
    eventSignature:
      'event BonusTargetEscrowCancelled(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)',
    label: 'MarketRouter.BonusTargetEscrowCancelled',
  },
  // Expiry is noisy on its own (fires once per offer at deadline); we
  // fold it into expire-offers and let the task coalesce.
  {
    taskName: 'expire-offers',
    contractKey: 'MarketRouter',
    eventSignature:
      'event BonusTargetEscrowExpired(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)',
    label: 'MarketRouter.BonusTargetEscrowExpired',
  },
  // Listings: LockListed or LockDelisted → sweep-listings re-runs
  // discovery and attempts any that are now fillable.
  {
    taskName: 'sweep-listings',
    contractKey: 'MarketRouter',
    eventSignature:
      'event LockListed(uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 listedAtTime, uint256 expiresAtTime)',
    label: 'MarketRouter.LockListed',
  },
  {
    taskName: 'sweep-listings',
    contractKey: 'MarketRouter',
    eventSignature:
      'event LockDelisted(uint256 indexed tokenId, address indexed seller, uint8 reason)',
    label: 'MarketRouter.LockDelisted',
  },
];

interface ResolvedHotEvent extends HotEventSpec {
  topic0: `0x${string}`;
}

const HOT_EVENTS: readonly ResolvedHotEvent[] = HOT_EVENT_SPECS.map((spec) => ({
  ...spec,
  topic0: getEventSelector(parseAbiItem(spec.eventSignature) as AbiEvent) as `0x${string}`,
}));

export interface HotSubscription {
  taskName: string;
  filter: LogFilter;
  /** Human-readable list of event names covered (for logs). */
  label: string;
}

/**
 * Resolve every hot-event subscription for the provided deployment.
 *
 * Rows whose contract address is missing/zero in the manifest are
 * silently dropped — this keeps the bus usable against partial
 * deployments (e.g. test staging where MarketRouter isn't wired up).
 *
 * Rows that target the same `(taskName, contract)` pair are collapsed
 * into a single subscription whose topic0 filter is the union of their
 * selectors.  That halves the number of `eth_subscribe('logs')` calls
 * at connect time and lets the RPC provider serve one stream per group.
 */
export function resolveHotSubscriptions(
  manifest: DeploymentManifest,
  log: (msg: string) => void,
): HotSubscription[] {
  type GroupKey = string;
  type Group = {
    taskName: string;
    address: Address;
    topics: Set<string>;
    labels: string[];
  };
  const groups = new Map<GroupKey, Group>();

  for (const row of HOT_EVENTS) {
    const address = getContractAddress(manifest, row.contractKey);
    if (!address || address === '0x0000000000000000000000000000000000000000') {
      log(`[hot_events] skipping ${row.label}: ${row.contractKey} not deployed`);
      continue;
    }
    const key = `${row.taskName}|${address.toLowerCase()}`;
    const existing = groups.get(key);
    if (existing) {
      existing.topics.add(row.topic0);
      existing.labels.push(row.label);
    } else {
      groups.set(key, {
        taskName: row.taskName,
        address,
        topics: new Set([row.topic0]),
        labels: [row.label],
      });
    }
  }

  const subs: HotSubscription[] = [];
  for (const g of groups.values()) {
    // eth_subscribe('logs', …) accepts `topics: [topic0Set, …]`.  We
    // only constrain topic0, leaving indexed arguments unconstrained so
    // every event on the contract matching any of our selectors gets
    // streamed through.  For the 2–3 topics per contract we currently
    // care about this fits comfortably below every provider's filter
    // limit (256 topics on Alchemy as of writing).
    const filter: LogFilter = {
      address: [g.address],
      topics: [[...g.topics]],
    };
    subs.push({
      taskName: g.taskName,
      filter,
      label: g.labels.join('+'),
    });
  }
  return subs;
}

/** Exposed for tests only — do not import from application code. */
export const _testOnly = {
  HOT_EVENT_SPECS,
  HOT_EVENTS,
};
