import { BigInt } from '@graphprotocol/graph-ts';

// Width must accommodate uint64-ish quantities (block numbers, timestamps).
// 20 chars covers 2^64 (~1.8e19) which is well past any practical Base block
// number or unix timestamp through year ~2554.
//
// MUST stay in sync with the consumer-side padding helpers:
// - `frontend/src/lib/delegationSessions.ts::computeBlockSortKeyCursor`
// - `workers/chat/src/lib/leaderboards/sync/sortKey.ts::computeBlockSortKey`
//   and `computeTimestampSortKey`
const SORT_KEY_NUMERIC_WIDTH = 20;

function padNumeric(value: string): string {
  let out = value;
  while (out.length < SORT_KEY_NUMERIC_WIDTH) {
    out = '0' + out;
  }
  return out;
}

// Block-based total-order key. Format: zero-padded blockNumber + ':' + entity id.
//
// Why: subgraph queries with `orderBy: blockNumber` alone are non-deterministic
// when multiple rows share the same blockNumber — Graph Node returns ties in
// arbitrary order, so a paged consumer using (lastBlock, lastId) cursor logic
// can permanently skip same-block rows when the page boundary lands inside a
// busy block. Sorting by this single deterministic key (orderBy: sortKey,
// orderDirection: asc) collapses the tie-break into the field itself.
export function blockSortKey(blockNumber: BigInt, id: string): string {
  return padNumeric(blockNumber.toString()) + ':' + id;
}

// Timestamp-based total-order key. Format: zero-padded timestamp + ':' + entity id.
//
// Used for entities that page by timestamp (e.g. `ShareholderClaimEvent` which
// does not currently expose `blockNumber`).
export function timestampSortKey(timestamp: BigInt, id: string): string {
  return padNumeric(timestamp.toString()) + ':' + id;
}
