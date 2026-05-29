import { Address, BigInt, dataSource, log } from '@graphprotocol/graph-ts';

import {
  VeClaimNFT as VeClaimNFTContract,
  AutoMaxSet,
  FurnaceChanged,
  MineMarketChanged,
  DelegationSessionUsed,
  LockAmountIncreased,
  LockCreated,
  LockExtended,
  LockMerged,
  LockUnlocked,
  ShareholderCheckpointFailed,
  SlopeDriftClamped,
  Transfer,
} from '../generated/VeClaimNFT/VeClaimNFT';

import {
  ActivityItem,
  MarketListing,
  User,
  VeLock,
  VeLockAutoMaxSetEvent,
  VeLockCreatedEvent,
  VeLockAmountIncreasedEvent,
  VeLockExtendedEvent,
  VeLockMergedEvent,
  VeLockTransferEvent,
  VeLockUnlockedEvent,
} from '../generated/schema';

import { recordDelegationSessionUsed } from '../utils/delegation';
import { saveActivityItem } from '../utils/activity';
import { eventId } from '../utils/id';
import { loadOrCreateProtocol, setBytesIfZero, ZERO_ADDRESS } from '../utils/protocol';
import { refreshTokenPricingSnapshot } from '../utils/tokenPricingSnapshot';
import { refreshAprAfterLockChange } from '../utils/aprSnapshot';
import { loadOrCreateUser } from '../utils/user';
import { MAX_LOCK_DURATION_SECONDS, currentVeWei } from '../utils/ve';

const ZERO = BigInt.fromI32(0);

function isZeroAddress(addr: Address): bool {
  return addr.toHexString() == ZERO_ADDRESS.toHexString();
}

function isLocalNetwork(): bool {
  return dataSource.network() == 'local';
}

function ensureUserVeFields(u: User): void {
  if (u.veBalanceWei === null) {
    u.veBalanceWei = ZERO;
  }
  if (u.totalLockedClaimWei === null) {
    u.totalLockedClaimWei = ZERO;
  }
}

// Stored ve snapshot at the lock's last activity. If missing on the stored entity, fall back
// to computing at the current event time as a best-effort approximation.
function lockVeSnapshot(l: VeLock, now: BigInt): BigInt {
  if (l.currentVeWei === null) {
    return currentVeWei(l.amountWei, l.lockEnd, now, l.autoMax);
  }
  return l.currentVeWei as BigInt;
}

// Replace a user's aggregate ve contribution for (one or more) locks, clamped to 0.
function replaceUserVeContribution(user: User, oldVe: BigInt, newVe: BigInt): void {
  ensureUserVeFields(user);

  let agg = user.veBalanceWei as BigInt;
  if (newVe.ge(oldVe)) {
    agg = agg.plus(newVe.minus(oldVe));
  } else {
    const diff = oldVe.minus(newVe);
    if (agg.ge(diff)) {
      agg = agg.minus(diff);
    } else {
      agg = ZERO;
    }
  }
  user.veBalanceWei = agg;
}

function loadOrCreateVeLock(tokenId: BigInt, owner: Address, now: BigInt): VeLock {
  const id = tokenId.toString();
  let l = VeLock.load(id);
  if (l == null) {
    const u = loadOrCreateUser(owner);
    ensureUserVeFields(u);

    l = new VeLock(id);
    l.tokenId = tokenId;
    l.owner = u.id;
    l.amountWei = ZERO;
    l.lockEnd = ZERO;
    l.autoMax = false;
    l.listed = false;
    l.createdAt = now;
    l.updatedAt = now;
    l.currentVeWei = ZERO;
    l.save();
  }
  return l as VeLock;
}

export function handleFurnaceChanged(event: FurnaceChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  // Track the latest configured Furnace address from canonical VeClaimNFT rewiring receipts.
  // If that new Furnace is itself a newly deployed indexed peer, operators must still update
  // the manifest/datasource set for full event coverage.
  protocol.furnace = event.params.newFurnace;
  protocol.save();
}

export function handleMineMarketChanged(event: MineMarketChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  // MineMarket is the MarketRouter in v1.0.0 deployments; keep the singleton on the latest
  // observed configured router rather than write-once seeding.
  protocol.marketRouter = event.params.newMineMarket;
  protocol.save();
}

export function handleLockCreated(event: LockCreated): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const user = loadOrCreateUser(event.params.user);
  ensureUserVeFields(user);

  const id = event.params.tokenId.toString();
  const l = new VeLock(id);
  l.tokenId = event.params.tokenId;
  l.owner = user.id;
  l.amountWei = event.params.amount;
  l.lockEnd = event.params.lockEnd;
  l.autoMax = event.params.autoMax;
  l.listed = false;
  l.createdAt = event.block.timestamp;
  l.updatedAt = event.block.timestamp;
  l.currentVeWei = currentVeWei(l.amountWei, l.lockEnd, event.block.timestamp, l.autoMax);
  l.save();

  // User aggregates (event-driven snapshots)
  user.totalLockedClaimWei = (user.totalLockedClaimWei as BigInt).plus(event.params.amount);
  replaceUserVeContribution(user, ZERO, l.currentVeWei as BigInt);
  user.save();

  const e = new VeLockCreatedEvent(eventId(event));
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.amountWei = event.params.amount;
  e.lockEnd = event.params.lockEnd;
  e.autoMax = event.params.autoMax;
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();

  refreshTokenPricingSnapshot(event.address, event.block.number, event.block.timestamp);
  refreshAprAfterLockChange(event.block.number, event.block.timestamp);
}

export function handleLockExtended(event: LockExtended): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const user = loadOrCreateUser(event.params.user);
  ensureUserVeFields(user);
  const now = event.block.timestamp;

  const l = loadOrCreateVeLock(event.params.tokenId, event.params.user, now);

  const oldEnd = l.lockEnd;
  const oldVe = lockVeSnapshot(l, now);

  l.owner = user.id;
  l.lockEnd = event.params.newEnd;
  l.updatedAt = now;
  const newVe = currentVeWei(l.amountWei, l.lockEnd, now, l.autoMax);
  l.currentVeWei = newVe;
  l.save();

  replaceUserVeContribution(user, oldVe, newVe);
  user.save();

  const e = new VeLockExtendedEvent(eventId(event));
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.oldEnd = oldEnd;
  e.newEnd = event.params.newEnd;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLockAmountIncreased(event: LockAmountIncreased): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const user = loadOrCreateUser(event.params.user);
  ensureUserVeFields(user);
  const now = event.block.timestamp;

  const l = loadOrCreateVeLock(event.params.tokenId, event.params.user, now);

  const oldVe = lockVeSnapshot(l, now);

  l.owner = user.id;
  l.amountWei = l.amountWei.plus(event.params.amountAdded);
  l.updatedAt = now;
  const newVe = currentVeWei(l.amountWei, l.lockEnd, now, l.autoMax);
  l.currentVeWei = newVe;
  l.save();

  user.totalLockedClaimWei = (user.totalLockedClaimWei as BigInt).plus(event.params.amountAdded);
  replaceUserVeContribution(user, oldVe, newVe);
  user.save();

  const e = new VeLockAmountIncreasedEvent(eventId(event));
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.amountAddedWei = event.params.amountAdded;
  e.amountAfterWei = l.amountWei;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();

  refreshTokenPricingSnapshot(event.address, event.block.number, event.block.timestamp);
  refreshAprAfterLockChange(event.block.number, event.block.timestamp);
}

export function handleLockMerged(event: LockMerged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const user = loadOrCreateUser(event.params.user);
  ensureUserVeFields(user);
  const now = event.block.timestamp;

  const fromLock = loadOrCreateVeLock(event.params.fromTokenId, event.params.user, now);
  const intoLock = loadOrCreateVeLock(event.params.intoTokenId, event.params.user, now);

  const oldFromVe = lockVeSnapshot(fromLock, now);
  const oldIntoVe = lockVeSnapshot(intoLock, now);

  // Destination lock remains owned by the user. The source lock is burned in the merge.
  intoLock.owner = user.id;

  if (fromLock.amountWei.ge(event.params.amountMoved)) {
    fromLock.amountWei = fromLock.amountWei.minus(event.params.amountMoved);
  } else {
    fromLock.amountWei = ZERO;
  }
  intoLock.amountWei = intoLock.amountWei.plus(event.params.amountMoved);

  fromLock.updatedAt = now;
  intoLock.updatedAt = now;

  // AutoMax propagate (contract: newAutoMax = into.autoMax || from.autoMax)
  intoLock.autoMax = intoLock.autoMax || fromLock.autoMax;

  // lockEnd semantics:
  // - if autoMax becomes true, the effective end is always now + MAX
  // - otherwise, merge keeps the max of the two ends
  if (intoLock.autoMax) {
    intoLock.lockEnd = now.plus(BigInt.fromI32(MAX_LOCK_DURATION_SECONDS));
  } else {
    if (fromLock.lockEnd.gt(intoLock.lockEnd)) {
      intoLock.lockEnd = fromLock.lockEnd;
    }
  }

  const zeroUser = loadOrCreateUser(ZERO_ADDRESS);
  fromLock.owner = zeroUser.id;

  // Deactivate any active MarketListing before clearing the listed flag.
  if (fromLock.listed) {
    const listing = MarketListing.load(fromLock.id);
    if (listing !== null && listing.active) {
      listing.active = false;
      listing.updatedAt = now;
      listing.save();
    }
  }
  fromLock.listed = false;

  const newFromVe = currentVeWei(fromLock.amountWei, fromLock.lockEnd, now, fromLock.autoMax);
  // Burned source lock: clear schedule fields only when no principal remains.
  if (fromLock.amountWei.equals(ZERO)) {
    fromLock.lockEnd = ZERO;
    fromLock.autoMax = false;
  }
  const newIntoVe = currentVeWei(intoLock.amountWei, intoLock.lockEnd, now, intoLock.autoMax);
  fromLock.currentVeWei = newFromVe;
  intoLock.currentVeWei = newIntoVe;

  fromLock.save();
  intoLock.save();

  const oldTotal = oldFromVe.plus(oldIntoVe);
  const newTotal = newFromVe.plus(newIntoVe);
  replaceUserVeContribution(user, oldTotal, newTotal);
  user.save();

  const e = new VeLockMergedEvent(eventId(event));
  e.user = user.id;
  e.fromTokenId = event.params.fromTokenId;
  e.intoTokenId = event.params.intoTokenId;
  e.amountMovedWei = event.params.amountMoved;
  e.fromAmountAfterWei = fromLock.amountWei;
  e.intoAmountAfterWei = intoLock.amountWei;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLockUnlocked(event: LockUnlocked): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const user = loadOrCreateUser(event.params.user);
  ensureUserVeFields(user);
  const now = event.block.timestamp;

  const l = loadOrCreateVeLock(event.params.tokenId, event.params.user, now);

  const oldVe = lockVeSnapshot(l, now);

  // Reduce principal (unlock burns the veNFT onchain).
  if (l.amountWei.ge(event.params.amountReturned)) {
    l.amountWei = l.amountWei.minus(event.params.amountReturned);
  } else {
    l.amountWei = ZERO;
  }

  const zeroUser = loadOrCreateUser(ZERO_ADDRESS);
  l.owner = zeroUser.id;

  // Deactivate any active MarketListing before clearing the listed flag.
  if (l.listed) {
    const listing = MarketListing.load(l.id);
    if (listing !== null && listing.active) {
      listing.active = false;
      listing.updatedAt = now;
      listing.save();
    }
  }
  l.listed = false;
  l.updatedAt = now;

  // Clear schedule fields when lock is fully drained to prevent stale lockEnd
  // misleading downstream consumers that inspect lockEnd without amountWei.
  if (l.amountWei.equals(ZERO)) {
    l.lockEnd = ZERO;
    l.autoMax = false;
  }

  const newVe = currentVeWei(l.amountWei, l.lockEnd, now, l.autoMax);
  l.currentVeWei = newVe;
  l.save();

  // User aggregates
  const locked = user.totalLockedClaimWei as BigInt;
  if (locked.ge(event.params.amountReturned)) {
    user.totalLockedClaimWei = locked.minus(event.params.amountReturned);
  } else {
    user.totalLockedClaimWei = ZERO;
  }

  replaceUserVeContribution(user, oldVe, newVe);
  user.save();

  const e = new VeLockUnlockedEvent(eventId(event));
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.amountReturnedWei = event.params.amountReturned;
  e.amountAfterWei = l.amountWei;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();

  refreshTokenPricingSnapshot(event.address, event.block.number, event.block.timestamp);
  refreshAprAfterLockChange(event.block.number, event.block.timestamp);
}

export function handleAutoMaxSet(event: AutoMaxSet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const now = event.block.timestamp;

  const user = loadOrCreateUser(event.params.user);
  ensureUserVeFields(user);

  const l = loadOrCreateVeLock(event.params.tokenId, event.params.user, now);

  const oldVe = lockVeSnapshot(l, now);

  // Mirror VeClaimNFT.setAutoMax: both enable AND disable refresh
  // `lockEnd` to `block.timestamp + MAX_LOCK_DURATION`. The same-state
  // (true → true) refresh path also rewrites `lockEnd` to `now + MAX`.
  // The previous mapping only updated `lockEnd` on enable, leaving the
  // disable path with a stale `lockEnd` from the prior enable; downstream
  // consumers (UI extend modal, autoCompound previews) then computed
  // wrong remaining-duration deltas and could build calldata that the
  // chain rejects. Source of truth: src/VeClaimNFT.sol:setAutoMax
  // (l.lockEnd = newEnd; l.lockStart = nowTs unconditionally on toggle).
  l.autoMax = event.params.autoMax;
  l.lockEnd = now.plus(BigInt.fromI32(MAX_LOCK_DURATION_SECONDS));
  l.updatedAt = now;

  const newVe = currentVeWei(l.amountWei, l.lockEnd, now, l.autoMax);
  l.currentVeWei = newVe;
  l.save();

  replaceUserVeContribution(user, oldVe, newVe);
  user.save();

  const e = new VeLockAutoMaxSetEvent(eventId(event));
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.autoMax = event.params.autoMax;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleTransfer(event: Transfer): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.veClaimNft = setBytesIfZero(protocol.veClaimNft, event.address);
  protocol.save();

  const now = event.block.timestamp;

  // Mint (from == 0): LockCreated handler owns lifecycle + aggregates.
  if (isZeroAddress(event.params.from)) {
    return;
  }

  // Self-transfer: no-op for aggregates. graph-ts Entity.load() returns a fresh
  // object each call, so loading the same user as both `fromUser` and `toUser`
  // causes the second .save() to overwrite the first with stale data, corrupting
  // totalLockedClaimWei and veBalanceWei.
  if (event.params.from.equals(event.params.to)) {
    return;
  }

  // Burn (to == 0):
  // - User burns are handled by lifecycle events (LockUnlocked / LockMerged).
  // - Furnace burns (sellback path via furnaceBurnAndWithdraw) have no lifecycle event,
  //   so we must update ownership + aggregates here.
  //
  // Reorg safety note:
  // - Some deployments start indexing mid-history. In that case Protocol.furnace may
  //   still be 0x0 when a burn Transfer is observed.
  // - We therefore resolve the canonical Furnace address via VeClaimNFT.furnace() at the
  //   indexed block (non-local networks) and only handle burns where `from` is Furnace.
  //   This avoids double-counting user burns where Transfer(to=0) precedes LockUnlocked/LockMerged.
  if (isZeroAddress(event.params.to)) {
    const fromUser = loadOrCreateUser(event.params.from);
    ensureUserVeFields(fromUser);

    const zeroUser = loadOrCreateUser(ZERO_ADDRESS);

    const lockId = event.params.tokenId.toString();
    let l = VeLock.load(lockId);

    const fromHex = event.params.from.toHexString();

    // Determine canonical Furnace address.
    // IMPORTANT: User burns (unlock/merge) emit Transfer(to=0) before the lifecycle event,
    // so we MUST NOT treat "lock still owned by from" as a burn signal.
    let furnaceAddr = Address.fromBytes(protocol.furnace);
    if (isZeroAddress(furnaceAddr) && !isLocalNetwork()) {
      const ve = VeClaimNFTContract.bind(event.address);
      const res = ve.try_furnace();
      if (!res.reverted) {
        furnaceAddr = res.value;

        // Opportunistic backfill: Furnace is immutable per deployment.
        if (!isZeroAddress(furnaceAddr)) {
          protocol.furnace = setBytesIfZero(protocol.furnace, furnaceAddr);
          protocol.save();
        }
      } else {
        log.warning(
          'VeClaimNFT burn skipped because furnace address is unknown and try_furnace() reverted (tokenId={}, from={}, tx={})',
          [lockId, fromHex, event.transaction.hash.toHexString()],
        );
      }
    }

    const fromIsFurnace = !isZeroAddress(furnaceAddr) && furnaceAddr.toHexString() == fromHex;
    if (!fromIsFurnace) {
      return;
    }

    // Ensure lock exists if we're handling the burn.
    if (l === null) {
      l = loadOrCreateVeLock(event.params.tokenId, event.params.from, now);
    }

    // If the lock was already cleared by a prior handler, don't double-handle.
    if ((l as VeLock).owner == zeroUser.id || (l as VeLock).amountWei.equals(ZERO)) {
      return;
    }

    // Snapshot lock state before burn.
    const amountWei = (l as VeLock).amountWei;
    const lockEnd = (l as VeLock).lockEnd;
    const autoMax = (l as VeLock).autoMax;
    const oldVe = lockVeSnapshot(l as VeLock, now);

    // Remove custody from aggregates.
    const locked = fromUser.totalLockedClaimWei as BigInt;
    if (locked.ge(amountWei)) {
      fromUser.totalLockedClaimWei = locked.minus(amountWei);
    } else {
      fromUser.totalLockedClaimWei = ZERO;
    }
    replaceUserVeContribution(fromUser, oldVe, ZERO);
    fromUser.save();

    // Mark lock as burned/unowned.
    (l as VeLock).owner = zeroUser.id;
    (l as VeLock).amountWei = ZERO;
    (l as VeLock).listed = false;
    (l as VeLock).updatedAt = now;
    (l as VeLock).currentVeWei = ZERO;
    (l as VeLock).save();

    // Record the burn transfer for completeness.
    const e = new VeLockTransferEvent(eventId(event));
    e.tokenId = event.params.tokenId;
    e.from = fromUser.id;
    e.to = null;
    e.amountWei = amountWei;
    e.lockEnd = lockEnd;
    e.autoMax = autoMax;
    e.timestamp = now;
    e.blockNumber = event.block.number;
    e.txHash = event.transaction.hash;
    e.save();

    // Furnace sellback moves CLAIM out of VeClaimNFT custody; the
    // `ClaimToken.balanceOf(VeClaimNFT)` denominator behind `lockedSupplyWei`
    // and `veAprBps24h` must be refreshed at the same block to stay coherent.
    refreshTokenPricingSnapshot(event.address, event.block.number, now);
    refreshAprAfterLockChange(event.block.number, now);

    return;
  }

  // Normal transfer: from -> to.
  const fromUser = loadOrCreateUser(event.params.from);
  const toUser = loadOrCreateUser(event.params.to);
  ensureUserVeFields(fromUser);
  ensureUserVeFields(toUser);

  const l = loadOrCreateVeLock(event.params.tokenId, event.params.from, now);

  // Snapshot lock state before transfer.
  const amountWei = l.amountWei;
  const lockEnd = l.lockEnd;
  const autoMax = l.autoMax;
  const oldVe = lockVeSnapshot(l, now);

  // Transfer is an activity boundary; snapshot ve at transfer time.
  const newVe = currentVeWei(amountWei, lockEnd, now, autoMax);

  // Update ownership + lock snapshot.
  l.owner = toUser.id;
  l.updatedAt = now;
  l.currentVeWei = newVe;

  // Invalidate any active marketplace listing: after an ERC-721 transfer the
  // seller no longer owns the lock, so the MarketRouter cannot settle it.
  if (l.listed) {
    l.listed = false;
    const listing = MarketListing.load(l.id);
    if (listing !== null && listing.active) {
      listing.active = false;
      listing.updatedAt = now;
      listing.save();
    }
  }

  l.save();

  // Move user aggregates.
  const fromLocked = fromUser.totalLockedClaimWei as BigInt;
  if (fromLocked.ge(amountWei)) {
    fromUser.totalLockedClaimWei = fromLocked.minus(amountWei);
  } else {
    fromUser.totalLockedClaimWei = ZERO;
  }
  replaceUserVeContribution(fromUser, oldVe, ZERO);
  fromUser.save();

  toUser.totalLockedClaimWei = (toUser.totalLockedClaimWei as BigInt).plus(amountWei);
  replaceUserVeContribution(toUser, ZERO, newVe);
  toUser.save();

  const e = new VeLockTransferEvent(eventId(event));
  e.tokenId = event.params.tokenId;
  e.from = fromUser.id;
  e.to = toUser.id;
  e.amountWei = amountWei;
  e.lockEnd = lockEnd;
  e.autoMax = autoMax;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleDelegationSessionUsed(event: DelegationSessionUsed): void {
  recordDelegationSessionUsed(
    event,
    event.params.user,
    event.params.delegate,
    event.params.actionType,
    event.params.permsUsed,
    event.params.refId,
    event.params.timestamp,
  );
}

export function handleSlopeDriftClamped(event: SlopeDriftClamped): void {
  const id = eventId(event);
  const a = new ActivityItem(id);
  a.kind = 'VE_SLOPE_DRIFT_CLAMPED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  saveActivityItem(a);
}

export function handleShareholderCheckpointFailed(event: ShareholderCheckpointFailed): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const a = new ActivityItem(id);
  a.kind = 'SHAREHOLDER_CHECKPOINT_FAILED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = user.id;
  saveActivityItem(a);
}
