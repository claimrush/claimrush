import { BigInt } from "@graphprotocol/graph-ts";

import { SessionSet } from "../generated/DelegationHub/DelegationHub";
import { DelegationSession, DelegationSessionSetEvent } from "../generated/schema";

import { eventId } from "../utils/id";
import { blockSortKey } from "../utils/sortKey";
import { loadOrCreateUser } from "../utils/user";

const ZERO = BigInt.fromI32(0);

function sessionId(userId: string, delegateId: string): string {
  return userId + "-" + delegateId;
}

export function handleSessionSet(event: SessionSet): void {
  const user = loadOrCreateUser(event.params.user);
  const delegate = loadOrCreateUser(event.params.delegate);

  // Since loadOrCreateUser uses Address.toHexString() (always lowercase in graph-ts),
  // there is no case-sensitivity collision risk. This is correct.

  const id = sessionId(user.id, delegate.id);
  let s = DelegationSession.load(id);
  if (s == null) {
    s = new DelegationSession(id);
    s.user = user.id;
    s.delegate = delegate.id;
    s.perms = ZERO;
    s.expiry = ZERO;
    s.createdAt = event.block.timestamp;
    s.updatedAt = event.block.timestamp;
    s.revokedAt = null;
    s.lastUsedAt = null;
    s.lastActionType = null;
    s.lastTxHash = null;
  }

  s.perms = event.params.perms;
  s.expiry = event.params.expiry;
  s.updatedAt = event.block.timestamp;

  // Revocation is represented by perms=0 AND expiry=0.
  // IMPORTANT: expiry=0 is immediately expired, not an active no-expiry session.
  const isRevocation = event.params.perms.equals(ZERO) && event.params.expiry.equals(ZERO);
  s.revokedAt = isRevocation ? event.block.timestamp : null;

  s.save();

  const evId = eventId(event);
  const ev = new DelegationSessionSetEvent(evId);
  ev.sortKey = blockSortKey(event.block.number, evId);
  ev.session = s.id;
  ev.user = user.id;
  ev.delegate = delegate.id;
  ev.perms = event.params.perms;
  ev.expiry = event.params.expiry;
  ev.isRevocation = isRevocation;
  ev.timestamp = event.block.timestamp;
  ev.blockNumber = event.block.number;
  ev.txHash = event.transaction.hash;
  ev.save();
}
