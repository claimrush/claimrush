import { Address, BigInt, Bytes } from '@graphprotocol/graph-ts';

import {
  DelegationSessionUsed,
  MinAutoCompoundEthSet,
  ShareholderAutoCompoundConfigured,
  ShareholderAutoCompoundExecuted,
  ShareholderAutoCompoundPaused,
  ShareholderAutoCompoundKeeperSet,
  ShareholderClaim,
  ShareholderFlush,
  ShareholderTakeoverAllocation,
  ShareholderWiringSet,
} from '../generated/ShareholderRoyalties/ShareholderRoyalties';

import {
  ActivityItem,
  Reign,
  Takeover,
  ShareholderAllocation,
  ShareholderAutoCompoundConfig,
  ShareholderAutoCompoundConfiguredEvent,
  ShareholderAutoCompoundExecutedEvent,
  ShareholderAutoCompoundPausedEvent,
  ShareholderAutoCompoundKeeper,
  ShareholderAutoCompoundKeeperSetEvent,
  ShareholderMinAutoCompoundEthSetEvent,
  ShareholderClaimEvent,
  ShareholderFlushEvent,
} from '../generated/schema';

import { eventId } from '../utils/id';
import { saveActivityItem } from '../utils/activity';
import { recordDelegationSessionUsed } from '../utils/delegation';
import { loadOrCreateProtocol, setBytesIfZero, ZERO_ADDRESS } from '../utils/protocol';
import { blockSortKey, timestampSortKey } from '../utils/sortKey';
import { loadOrCreateUser } from '../utils/user';
import { recordShareholderEthForApr } from '../utils/aprSnapshot';
import { refreshTokenPricingSnapshot } from '../utils/tokenPricingSnapshot';

const ZERO = BigInt.fromI32(0);

/**
 * Ensure the Reign entity exists when indexing starts mid-history.
 * Some ShareholderRoyalties events refer to a reignId without guaranteeing that
 * the MineCore Takeover event is in-range for this subgraph deployment.
 */
function ensureReignForForeignKey(
  reignId: BigInt,
  ts: BigInt,
  blockNumber: BigInt,
  txHash: Bytes,
): string {
  const id = reignId.toString();
  let r = Reign.load(id);
  if (r !== null) {
    return id;
  }

  const zeroUser = loadOrCreateUser(ZERO_ADDRESS);

  // Non-null FK: startedByTakeover requires a Takeover entity. Use the same
  // prefix ("missing-") as minecore.ts so that both code paths converge on
  // the same placeholder entity, preventing orphaned Takeover duplicates when
  // mid-history indexing triggers placeholder creation from both files.
  const placeholderTakeoverId = 'missing-' + id;
  let t = Takeover.load(placeholderTakeoverId);
  if (t === null) {
    t = new Takeover(placeholderTakeoverId);
    t.sortKey = blockSortKey(blockNumber, placeholderTakeoverId);
    t.reign = id;
    t.previousKing = null;
    t.newKing = zeroUser.id;
    t.pricePaidWei = ZERO;
    t.referencePriceWei = ZERO;
    t.timestamp = ts;
    t.blockNumber = blockNumber;
    t.txHash = txHash;
    t.save();
  }

  r = new Reign(id);
  r.reignId = reignId;
  r.king = zeroUser.id;
  r.startTime = ts;
  r.startedByTakeover = placeholderTakeoverId;

  // Best-effort previous link (sequential reign ids).
  if (reignId.gt(BigInt.fromI32(1))) {
    r.previousReign = reignId.minus(BigInt.fromI32(1)).toString();
  }

  r.save();
  return id;
}

export function handleShareholderWiringSet(event: ShareholderWiringSet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = event.address;
  protocol.mineCore = event.params.mineCore;
  protocol.marketRouter = event.params.mineMarket;
  protocol.furnace = event.params.furnace;
  protocol.save();
}

export function handleShareholderTakeoverAllocation(event: ShareholderTakeoverAllocation): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);
  // Genesis takeover emits reignId=0 as a sentinel; attribute to Reign #1
  // so no phantom Reign #0 entity is created.
  const effectiveReignId = event.params.reignId.equals(ZERO)
    ? BigInt.fromI32(1)
    : event.params.reignId;
  const reignIdStr = ensureReignForForeignKey(
    effectiveReignId,
    event.block.timestamp,
    event.block.number,
    event.transaction.hash,
  );

  const e = new ShareholderAllocation(id);
  e.reign = reignIdStr;
  e.amountEthWei = event.params.amountEth;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  // Flow source for the veAPR numerator. Refresh the pricing singleton first
  // so the recompute reads claimUsd / ethUsd / lockedSupplyWei at the same
  // block as the allocation.
  const veNftBytes = protocol.veClaimNft;
  if (veNftBytes.toHexString() != ZERO_ADDRESS.toHexString()) {
    refreshTokenPricingSnapshot(
      Address.fromBytes(veNftBytes as Bytes),
      event.block.number,
      event.block.timestamp,
    );
  }
  recordShareholderEthForApr(
    event.block.number,
    event.block.timestamp,
    event.params.amountEth,
  );
}

export function handleShareholderFlush(event: ShareholderFlush): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);
  const e = new ShareholderFlushEvent(id);
  e.amountEthWei = event.params.amountEth;
  e.deltaEthPerVeWei = event.params.deltaEthPerVe;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleShareholderClaim(event: ShareholderClaim): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);

  const user = loadOrCreateUser(event.params.user);

  const e = new ShareholderClaimEvent(id);
  e.sortKey = timestampSortKey(event.block.timestamp, id);
  e.user = user.id;
  e.mode = event.params.mode;
  e.amountEthWei = event.params.amountEth;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  user.shareholderEthClaimedWei = user.shareholderEthClaimedWei.plus(event.params.amountEth);
  user.save();

  // Activity feed. Mode-aware kind so the feed can render the right label:
  //   mode == 0 → plain ETH payout ("Collect ETH")
  //   mode != 0 → LOCK_FURNACE auto-compound ("Collect & Lock"). The contract
  //   pairs this with a `ShareholderAutoCompoundExecuted` log in the same tx;
  //   that one feeds the dedicated `ShareholderAutoCompoundExecutedEvent` row
  //   above for full payload (tokenId, executor, effectiveDurationSeconds),
  //   while this activity item is the canonical user-facing feed row.
  const a = new ActivityItem(id);
  a.kind = event.params.mode == 0 ? 'SHAREHOLDER_CLAIM' : 'SHAREHOLDER_AUTO_COMPOUND';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = null;
  a.user = user.id;
  a.otherUser = null;
  a.amountEthWei = event.params.amountEth;
  a.amountClaimWei = null;
  saveActivityItem(a);
}

export function handleShareholderAutoCompoundConfigured(
  event: ShareholderAutoCompoundConfigured,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);

  const user = loadOrCreateUser(event.params.user);
  const e = new ShareholderAutoCompoundConfiguredEvent(id);
  e.user = user.id;
  e.enabled = event.params.enabled;
  e.tokenId = event.params.tokenId;
  e.durationSeconds = event.params.durationSeconds;
  // ABI param is already BigInt (uint32/uint256 encoded); schema expects BigInt.
  e.minCadenceSeconds = event.params.minCadenceSeconds;
  e.minEthToCompoundWei = event.params.minEthToCompound;
  e.maxSlippageBps = event.params.maxSlippageBps;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  // Current-state mirror — backs the "Eternal Lock" predicate that the activity
  // feed renders client-side. Reconfiguring resets the paused flag (the contract
  // clears the pause when the user re-enables their auto-compound).
  let cfg = ShareholderAutoCompoundConfig.load(user.id);
  if (cfg == null) {
    cfg = new ShareholderAutoCompoundConfig(user.id);
    cfg.user = user.id;
    cfg.pausedReasonCode = 0;
  }
  cfg.enabled = event.params.enabled;
  cfg.paused = false;
  cfg.tokenId = event.params.tokenId;
  cfg.durationSeconds = event.params.durationSeconds;
  cfg.minCadenceSeconds = event.params.minCadenceSeconds;
  cfg.minEthToCompoundWei = event.params.minEthToCompound;
  cfg.maxSlippageBps = event.params.maxSlippageBps;
  cfg.updatedAt = event.block.timestamp;
  cfg.save();
}

export function handleShareholderAutoCompoundPaused(event: ShareholderAutoCompoundPaused): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);

  const user = loadOrCreateUser(event.params.user);

  const e = new ShareholderAutoCompoundPausedEvent(id);
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.reasonCode = event.params.reasonCode;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  // Mirror to current-state config. A Paused event may arrive before any
  // Configured event when indexing mid-history; seed sane defaults so the
  // entity exists with paused=true and the eternal-lock predicate evaluates
  // to false on this user until a fresh Configured arrives.
  let cfg = ShareholderAutoCompoundConfig.load(user.id);
  if (cfg == null) {
    cfg = new ShareholderAutoCompoundConfig(user.id);
    cfg.user = user.id;
    cfg.enabled = false;
    cfg.tokenId = event.params.tokenId;
    cfg.durationSeconds = ZERO;
    cfg.minCadenceSeconds = ZERO;
    cfg.minEthToCompoundWei = ZERO;
    cfg.maxSlippageBps = ZERO;
  }
  cfg.paused = true;
  cfg.pausedReasonCode = event.params.reasonCode;
  cfg.updatedAt = event.block.timestamp;
  cfg.save();
}

export function handleShareholderAutoCompoundExecuted(
  event: ShareholderAutoCompoundExecuted,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);

  const user = loadOrCreateUser(event.params.user);
  const executor = loadOrCreateUser(event.params.executor);

  const e = new ShareholderAutoCompoundExecutedEvent(id);
  e.user = user.id;
  e.executor = executor.id;
  e.amountEthWei = event.params.amountEth;
  e.tokenId = event.params.tokenId;
  e.effectiveDurationSeconds = event.params.effectiveDurationSeconds;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleShareholderAutoCompoundKeeperSet(
  event: ShareholderAutoCompoundKeeperSet,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const id = eventId(event);

  const keeper = loadOrCreateUser(event.params.keeper);

  // Rolling allowlist state: last-write-wins per keeper address.
  let k = ShareholderAutoCompoundKeeper.load(keeper.id);
  if (k == null) {
    k = new ShareholderAutoCompoundKeeper(keeper.id);
    k.keeper = keeper.id;
    k.allowed = false;
    k.updatedAt = event.block.timestamp;
  }
  k.allowed = event.params.allowed;
  k.updatedAt = event.block.timestamp;
  k.save();

  const e = new ShareholderAutoCompoundKeeperSetEvent(id);
  e.keeper = keeper.id;
  e.allowed = event.params.allowed;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleMinAutoCompoundEthSet(event: MinAutoCompoundEthSet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.shareholderRoyalties = setBytesIfZero(protocol.shareholderRoyalties, event.address);
  protocol.save();

  const e = new ShareholderMinAutoCompoundEthSetEvent(eventId(event));
  e.oldFloorWei = event.params.oldFloor;
  e.newFloorWei = event.params.newFloor;
  e.timestamp = event.block.timestamp;
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
