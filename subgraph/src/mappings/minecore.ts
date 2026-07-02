import { Address, BigInt, Bytes, ethereum } from '@graphprotocol/graph-ts';

import {
  DelegationSessionUsed,
  EntryTokenRegistrySet,
  FurnaceChanged,
  KingEthCredited,
  KingEthPaid,
  KingWithdrawal,
  KingWithdrawalTo,
  RefundCredited,
  RefundWithdrawn,
  KingAutoLockConfigured,
  KingAutoLockExecuted,
  KingAutoLockFailed,
  KingAutoLockSkipped,
  KingClaimLiquidPaid,
  ReignFinalized,
  ReignRecipientsSet,
  ShareholderRoyaltiesFlushFailed,
  ShareholderRoyaltiesTakeoverFailed,
  Takeover as TakeoverEvent,
  TakeoversPausedChanged,
} from '../generated/MineCore/MineCore';

import { EntryTokenRegistry as EntryTokenRegistryTemplate } from '../generated/templates';

import {
  ActivityItem,
  EntryTokenRegistry as EntryTokenRegistryEntity,
  KingWithdrawalEvent,
  KingWithdrawalToEvent,
  RefundCreditedEvent,
  RefundWithdrawnEvent,
  Reign,
  ReignFinalizedEvent,
  ReignRecipientsSetEvent,
  ReignRecipientsState,
  ShareholderRoyaltiesFlushFailedEvent,
  ShareholderRoyaltiesTakeoverFailedEvent,
  Takeover,
} from '../generated/schema';

import { eventId } from '../utils/id';
import { saveActivityItem } from '../utils/activity';
import { recordDelegationSessionUsed } from '../utils/delegation';
import { loadOrCreateProtocol, setBytesIfZero, ZERO_ADDRESS } from '../utils/protocol';
import { snapshotEntryTokenRegistry } from '../utils/entryTokenRegistryInit';
import { blockSortKey } from '../utils/sortKey';
import { loadOrCreateUser } from '../utils/user';

const ZERO = BigInt.fromI32(0);

// MineCore.Takeover(uint256,address,address,uint256,uint256,uint256)
const TAKEOVER_SIG = Bytes.fromHexString(
  '0x9e8ea9ebe1eff3171e76905f1ded95f86073dde0bf181d85612dead42f2e430c',
) as Bytes;

// True if the tx receipt contains a log with topic0 == sig.
function receiptHasTopic(
  receipt: ethereum.TransactionReceipt | null,
  sig: Bytes,
  emitter: Address,
): bool {
  if (receipt == null) return false;

  const logs = (receipt as ethereum.TransactionReceipt).logs;
  for (let i = 0; i < logs.length; i++) {
    const log = logs[i];
    // Poisoning resistance: only consider logs from the expected contract.
    if (log.address.toHexString() != emitter.toHexString()) continue;
    if (log.topics.length == 0) continue;
    if (log.topics[0].toHexString() == sig.toHexString()) return true;
  }
  return false;
}

function isZeroAddress(addr: Address): bool {
  return addr.toHexString() == ZERO_ADDRESS.toHexString();
}

export function handleEntryTokenRegistrySet(event: EntryTokenRegistrySet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);

  const prev = protocol.mineCoreEntryTokenRegistry;
  protocol.mineCoreEntryTokenRegistry = event.params.registry;
  protocol.save();

  // Start indexing the registry contract from this block forward.
  let shouldCreate = false;
  if (prev === null) {
    shouldCreate = true;
  } else {
    const prevHex = (prev as Bytes).toHexString();
    const nextHex = event.params.registry.toHexString();
    if (prevHex != nextHex) {
      shouldCreate = true;
    }
  }
  if (shouldCreate) {
    const registryId = event.params.registry.toHexString();

    // Prevent duplicate dynamic data sources when both MineCore and Furnace
    // wire the same EntryTokenRegistry address.
    let r = EntryTokenRegistryEntity.load(registryId);
    if (r == null) {
      r = new EntryTokenRegistryEntity(registryId);
      r.address = event.params.registry;
      r.updatedAt = event.block.timestamp;
      r.save();

      EntryTokenRegistryTemplate.create(event.params.registry);
    }

    // Snapshot current config via onchain reads (skipped on local networks).
    snapshotEntryTokenRegistry(event.params.registry, event.block.timestamp, event.block.number);
  }
}

export function handleTakeoversPausedChanged(event: TakeoversPausedChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.takeoversPaused = event.params.paused;
  protocol.save();
}

export function handleFurnaceChanged(event: FurnaceChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  // Keep the singleton on the latest observed MineCore -> Furnace wiring.
  protocol.furnace = event.params.newFurnace;
  protocol.save();
}

export function handleTakeover(event: TakeoverEvent): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const takeoverId = eventId(event);

  const newKingUser = loadOrCreateUser(event.params.newKing);
  const previousKingAddr = event.params.previousKing;
  let previousKingUserId = '';
  if (!isZeroAddress(previousKingAddr)) {
    previousKingUserId = loadOrCreateUser(previousKingAddr).id;
  }

  // --- Takeover entity
  const takeover = new Takeover(takeoverId);
  takeover.sortKey = blockSortKey(event.block.number, takeoverId);
  takeover.reign = event.params.reignId.toString();
  if (previousKingUserId.length == 0) {
    takeover.previousKing = null;
  } else {
    takeover.previousKing = previousKingUserId;
  }
  takeover.newKing = newKingUser.id;
  takeover.pricePaidWei = event.params.pricePaid;
  takeover.referencePriceWei = event.params.referencePrice;
  takeover.timestamp = event.params.timestamp;
  takeover.blockNumber = event.block.number;
  takeover.txHash = event.transaction.hash;
  takeover.save();

  // --- Reign entity
  const reignId = event.params.reignId.toString();
  // contract ever resets reignId (e.g., after a proxy upgrade), historical Reign
  // entities could be overwritten. This is extremely unlikely given the contract
  // design but worth noting.
  // If a reign ID is ever skipped (e.g., genesis sentinel), the link breaks silently.
  let reign = Reign.load(reignId);
  if (reign == null) {
    reign = new Reign(reignId);
    reign.reignId = event.params.reignId;
    reign.king = newKingUser.id;
    reign.startTime = event.params.timestamp;
    reign.startedByTakeover = takeoverId;

    // Best-effort prev link (sequential reign ids)
    if (event.params.reignId.gt(BigInt.fromI32(1))) {
      reign.previousReign = event.params.reignId.minus(BigInt.fromI32(1)).toString();
    }
  } else {
    // reorg replay but produces orphaned Takeover entities in the store.
    // If it already exists, keep existing totals/finalization, but refresh king & start.
    reign.king = newKingUser.id;
    reign.startTime = event.params.timestamp;
    reign.startedByTakeover = takeoverId;
  }
  reign.save();

  // --- User aggregates
  newKingUser.takeoverCount = newKingUser.takeoverCount + 1;
  newKingUser.ethSpentOnTakeoversWei = newKingUser.ethSpentOnTakeoversWei.plus(
    event.params.pricePaid,
  );
  newKingUser.save();

  // --- Activity feed
  const a = new ActivityItem(takeoverId);
  a.kind = 'TAKEOVER';
  a.timestamp = event.params.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = event.params.reignId;
  a.user = newKingUser.id;
  a.amountEthWei = event.params.pricePaid;
  if (previousKingUserId.length != 0) {
    a.otherUser = previousKingUserId;
  }
  saveActivityItem(a);
}

export function handleReignFinalized(event: ReignFinalized): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);

  const reignId = event.params.reignId.toString();
  const kingUser = loadOrCreateUser(event.params.king);

  let reign = Reign.load(reignId);
  if (reign == null) {
    // If the subgraph starts mid-history, we may see finalization without the
    // corresponding Takeover event in our indexed range.
    // Create a placeholder Takeover to satisfy the non-null relationship.
    const placeholderTakeoverId = 'missing-' + reignId;

    const t = new Takeover(placeholderTakeoverId);
    t.sortKey = blockSortKey(event.block.number, placeholderTakeoverId);
    t.reign = reignId;
    t.newKing = kingUser.id;
    t.pricePaidWei = ZERO;
    t.referencePriceWei = ZERO;
    t.timestamp = event.params.startTime;
    t.blockNumber = event.block.number;
    t.txHash = event.transaction.hash;
    t.save();

    reign = new Reign(reignId);
    reign.reignId = event.params.reignId;
    reign.king = kingUser.id;
    reign.startTime = event.params.startTime;
    reign.startedByTakeover = placeholderTakeoverId;
  }

  const e = new ReignFinalizedEvent(id);
  e.sortKey = blockSortKey(event.block.number, id);
  e.reign = reignId;
  e.king = kingUser.id;
  e.startTime = event.params.startTime;
  e.endTime = event.params.endTime;
  e.totalClaimMinedWei = event.params.totalClaimMined;
  e.totalEthToKingWei = event.params.totalEthToKing;
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();

  // Update reign
  reign.king = kingUser.id;
  reign.startTime = event.params.startTime;
  reign.endTime = event.params.endTime;
  reign.totalClaimMinedWei = event.params.totalClaimMined;
  reign.totalEthToKingWei = event.params.totalEthToKing;
  reign.finalizedBy = id;
  reign.save();

  // User aggregates
  kingUser.kingClaimMinedWei = kingUser.kingClaimMinedWei.plus(event.params.totalClaimMined);
  const reignDuration = event.params.endTime.minus(event.params.startTime);
  // Clamp to i32 max to prevent negative longestReignSeconds on pathological inputs.
  // NOTE: This is already correctly handled with the MAX_I32 clamp below. The
  // pathological case requires a reign lasting >68 years, which is impossible
  // in practice, but the defensive clamp is still best practice.
  // VERIFIED: Clamp logic is correct — no action needed.
  const MAX_I32 = BigInt.fromI32(2147483647);
  const reignDurationI32 = reignDuration.gt(MAX_I32) ? 2147483647 : reignDuration.toI32();
  if (reignDurationI32 > kingUser.longestReignSeconds) {
    kingUser.longestReignSeconds = reignDurationI32;
  }
  kingUser.save();

  // Activity feed
  const a = new ActivityItem(id);
  a.kind = 'REIGN_FINALIZED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = event.params.reignId;
  a.user = kingUser.id;
  a.amountEthWei = event.params.totalEthToKing;
  a.amountClaimWei = event.params.totalClaimMined;
  saveActivityItem(a);
}

export function handleKingAutoLockConfigured(event: KingAutoLockConfigured): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const a = new ActivityItem(id);
  a.kind = 'KING_AUTOLOCK_CONFIGURED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = user.id;

  // Existing-lock mode: targetTokenId is the destination.
  // Create-once mode: targetTokenId == 0 and pinnedTokenId (if any) is the destination.
  if (event.params.targetTokenId.gt(ZERO)) {
    a.tokenId = event.params.targetTokenId;
  } else if (event.params.pinnedTokenId.gt(ZERO)) {
    a.tokenId = event.params.pinnedTokenId;
  }

  saveActivityItem(a);
}

// `principalClaim` here is the LOCKED slice only — the liquid slice (if any) is
// settled separately via KingClaimLiquidPaid. The authoritative total mined for
// the reign remains ReignFinalized.totalClaimMined.
export function handleKingAutoLockExecuted(event: KingAutoLockExecuted): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const a = new ActivityItem(id);
  a.kind = 'KING_AUTOLOCK_EXECUTED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = event.params.reignId;
  a.user = user.id;
  a.tokenId = event.params.tokenIdUsed;
  a.amountClaimWei = event.params.principalClaim;
  saveActivityItem(a);
}

// Liquid CLAIM slice paid directly to the dethroned King's recipient at
// settlement. `liquidBps` is the applied fraction of the reign's mined CLAIM;
// the remainder is force-locked (KingAutoLockExecuted / Skipped / Failed). The
// reign entity is enriched so per-reign liquid accounting is queryable without
// replaying the takeover window.
export function handleKingClaimLiquidPaid(event: KingClaimLiquidPaid): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const recipient = loadOrCreateUser(event.params.recipient);

  const a = new ActivityItem(id);
  a.kind = 'KING_CLAIM_LIQUID_PAID';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = event.params.reignId;
  a.user = recipient.id;
  a.amountClaimWei = event.params.amount;
  a.bps = event.params.liquidBps;
  saveActivityItem(a);

  // The dethroned King's reign was created at their takeover, so it exists here
  // regardless of event ordering within the settlement tx.
  const reign = Reign.load(event.params.reignId.toString());
  if (reign != null) {
    reign.liquidClaimPaidWei = event.params.amount;
    reign.liquidBpsApplied = event.params.liquidBps;
    reign.save();
  }
}

export function handleKingAutoLockSkipped(event: KingAutoLockSkipped): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const a = new ActivityItem(id);
  a.kind = 'KING_AUTOLOCK_SKIPPED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = event.params.reignId;
  a.user = user.id;
  a.amountClaimWei = event.params.principalClaim;
  saveActivityItem(a);
}

export function handleKingAutoLockFailed(event: KingAutoLockFailed): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const a = new ActivityItem(id);
  a.kind = 'KING_AUTOLOCK_FAILED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.reignId = event.params.reignId;
  a.user = user.id;
  a.amountClaimWei = event.params.principalClaim;
  saveActivityItem(a);
}

export function handleKingWithdrawal(event: KingWithdrawal): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  // Kept as an additional analytics entity; not part of the minimum UI schema.
  const id = eventId(event);

  const kingUser = loadOrCreateUser(event.params.king);

  const e = new KingWithdrawalEvent(id);
  e.king = kingUser.id;
  // Schema field is `amount` (not `amountWei`).
  e.amount = event.params.amount;
  e.blockNumber = event.block.number;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleKingWithdrawalTo(event: KingWithdrawalTo): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);

  const kingUser = loadOrCreateUser(event.params.king);
  const toUser = loadOrCreateUser(event.params.to);

  const e = new KingWithdrawalToEvent(id);
  e.king = kingUser.id;
  e.to = toUser.id;
  e.amount = event.params.amount;
  e.blockNumber = event.block.number;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleRefundCredited(event: RefundCredited): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const to = loadOrCreateUser(event.params.to);

  const e = new RefundCreditedEvent(id);
  e.to = to.id;
  e.amount = event.params.amount;
  e.blockNumber = event.block.number;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleRefundWithdrawn(event: RefundWithdrawn): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);
  const to = loadOrCreateUser(event.params.to);

  const e = new RefundWithdrawnEvent(id);
  e.user = user.id;
  e.to = to.id;
  e.amount = event.params.amount;
  e.blockNumber = event.block.number;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleShareholderRoyaltiesTakeoverFailed(
  event: ShareholderRoyaltiesTakeoverFailed,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);

  const e = new ShareholderRoyaltiesTakeoverFailedEvent(id);
  e.reignId = event.params.reignId;
  e.amountEthWei = event.params.amountEth;
  e.reason = event.params.reason;
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleShareholderRoyaltiesFlushFailed(
  event: ShareholderRoyaltiesFlushFailed,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);

  const e = new ShareholderRoyaltiesFlushFailedEvent(id);
  e.reason = event.params.reason;
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleReignRecipientsSet(event: ReignRecipientsSet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);

  const reignId = event.params.reignId.toString();
  const kingUser = loadOrCreateUser(event.params.king);

  // Rolling state: used to detect whether this is a mid-reign update vs the
  // initial recipients config emitted during takeover.
  //
  // IMPORTANT: the subgraph may start indexing mid-history. In that case, the first
  // observed ReignRecipientsSet for a reign is very likely a mid-reign update
  // (not the takeover-time config). We therefore use the tx receipt: takeover
  // transactions also emit MineCore.Takeover in the same tx, while mid-reign
  // updates do not.
  let state = ReignRecipientsState.load(reignId);
  let isMidReignUpdate = false;
  if (state == null) {
    isMidReignUpdate = !receiptHasTopic(event.receipt, TAKEOVER_SIG, event.address);

    state = new ReignRecipientsState(reignId);
    state.reignId = event.params.reignId;
    state.king = kingUser.id;
    state.ethRecipient = event.params.ethRecipient;
    state.claimRecipient = event.params.claimRecipient;
    state.updateCount = -1; // Will be incremented to 0 after the initial set
    state.createdAt = event.block.timestamp;
    state.updatedAt = event.block.timestamp;
    state.firstSetTxHash = event.transaction.hash;
    state.firstSetTimestamp = event.block.timestamp;
    state.lastSetTxHash = event.transaction.hash;
    state.lastSetTimestamp = event.block.timestamp;
  } else {
    // Any ReignRecipientsSet after the first indexed one for this reign is a mid-reign update.
    isMidReignUpdate = true;
  }

  state.king = kingUser.id;
  state.ethRecipient = event.params.ethRecipient;
  state.claimRecipient = event.params.claimRecipient;
  state.updateCount = state.updateCount + 1;
  state.updatedAt = event.block.timestamp;
  state.lastSetTxHash = event.transaction.hash;
  state.lastSetTimestamp = event.block.timestamp;
  state.save();

  const e = new ReignRecipientsSetEvent(id);
  e.sortKey = blockSortKey(event.block.number, id);
  e.reignId = event.params.reignId;
  e.king = kingUser.id;
  e.ethRecipient = event.params.ethRecipient;
  e.claimRecipient = event.params.claimRecipient;
  e.isMidReignUpdate = isMidReignUpdate;
  e.timestamp = event.block.timestamp;
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

export function handleKingEthPaid(event: KingEthPaid): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const recipientUser = loadOrCreateUser(event.params.recipient);

  const a = new ActivityItem(id);
  a.kind = 'KING_ETH_PAID';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = recipientUser.id;
  a.amountEthWei = event.params.amount;
  saveActivityItem(a);
}

// Emitted when the best-effort push of the dethroned reign's 75% ETH share
// FAILS and the amount is credited to the pull bucket `kingEthBalance[recipient]`.
// Without this handler, `KingEthPaid` would over-represent delivered payouts
// and any reconciliation of `kingEthBalance` via events alone would silently
// miss the credit leg (indexers would then show an incorrect outstanding
// bucket for `recipient` until a subsequent `KingWithdrawal[To]`).
export function handleKingEthCredited(event: KingEthCredited): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.mineCore = setBytesIfZero(protocol.mineCore, event.address);
  protocol.save();

  const id = eventId(event);
  const recipientUser = loadOrCreateUser(event.params.recipient);

  const a = new ActivityItem(id);
  a.kind = 'KING_ETH_CREDITED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = recipientUser.id;
  a.amountEthWei = event.params.amount;
  saveActivityItem(a);
}
