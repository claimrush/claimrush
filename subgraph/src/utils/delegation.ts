import { Address, BigInt, ethereum } from '@graphprotocol/graph-ts';

import { DelegationSession, DelegationSessionUse } from '../generated/schema';

import { eventId } from './id';
import { blockSortKey } from './sortKey';
import { loadOrCreateUser } from './user';

function sessionId(userId: string, delegateId: string): string {
  return userId + '-' + delegateId;
}

function actionTypeEnum(actionTypeId: i32): string {
  // See contracts: src/lib/DelegationActionTypes.sol
  if (actionTypeId == 1) return 'TAKEOVER';
  if (actionTypeId == 2) return 'REIGN_RECIPIENTS';
  if (actionTypeId >= 10 && actionTypeId <= 13) return 'CLAIM';
  if (actionTypeId >= 20 && actionTypeId <= 22) return 'FURNACE_ENTER';
  if (actionTypeId >= 30 && actionTypeId <= 32) return 'VE_LOCK';
  if (actionTypeId >= 40 && actionTypeId <= 42) return 'CONFIG';
  return 'UNKNOWN';
}

export function recordDelegationSessionUsed(
  event: ethereum.Event,
  userAddr: Address,
  delegateAddr: Address,
  actionTypeId: i32,
  permsUsed: BigInt,
  refId: BigInt,
  timestamp: BigInt,
): void {
  const user = loadOrCreateUser(userAddr);
  const delegate = loadOrCreateUser(delegateAddr);

  const id = sessionId(user.id, delegate.id);
  let session = DelegationSession.load(id);
  if (session == null) {
    // Mid-history indexing: SessionSet may be missing. Expiry unknown — use a far-future
    // sentinel so UI queries (`perms > 0 && expiry >= now`) do not treat the session as revoked.
    session = new DelegationSession(id);
    session.user = user.id;
    session.delegate = delegate.id;
    session.perms = permsUsed; // Best-effort: at least the perms that were just used
    session.expiry = BigInt.fromI64(4294967295);
    session.createdAt = timestamp;
    session.updatedAt = timestamp;
    session.revokedAt = null;
    session.lastUsedAt = null;
    session.lastActionType = null;
    session.lastTxHash = null;
  }

  // For mid-history sessions, accumulate observed perms via bitwise OR
  // to avoid narrowing the permission set on subsequent usage events.
  session.perms = session.perms.bitOr(permsUsed);

  const kind = actionTypeEnum(actionTypeId);

  session.lastUsedAt = timestamp;
  session.lastActionType = kind;
  session.lastTxHash = event.transaction.hash;
  session.updatedAt = timestamp;
  session.save();

  const useId = eventId(event);
  const use = new DelegationSessionUse(useId);
  use.sortKey = blockSortKey(event.block.number, useId);
  use.session = session.id;
  use.user = user.id;
  use.delegate = delegate.id;
  use.actionType = kind;
  use.actionTypeId = actionTypeId;
  use.permsUsed = permsUsed;
  use.refId = refId;
  use.timestamp = timestamp;
  use.blockNumber = event.block.number;
  use.txHash = event.transaction.hash;
  use.emitter = event.address;
  use.save();
}
