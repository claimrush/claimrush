import { Address, BigInt, Bytes, dataSource, ethereum } from '@graphprotocol/graph-ts';

import {
  MarketRouter,
  BonusTargetEscrowExecuted,
  BonusTargetEscrowAutoFurnaceExecuted,
  BonusTargetEscrowConfigured,
  BonusTargetEscrowCancelled,
  BonusTargetEscrowExpired,
  BonusTargetEscrowExpiryExtended,
  BonusTargetEscrowCreated,
  BonusTargetEscrowParamsChanged,
  LockDelisted,
  LockListed,
  ListingSettled,
  MarketSellToFurnace,
  SettlementKeeperSet,
  TradingPausedChanged,
} from '../generated/MarketRouter/MarketRouter';

import { VeClaimNFT as VeClaimNFTContract } from '../generated/VeClaimNFT/VeClaimNFT';

import {
  ActivityItem,
  MarketListing,
  MarketLockDelistedEvent,
  MarketLockListedEvent,
  ListingSettledEvent,
  MarketSellToFurnaceEvent,
  // NOTE: MarketTradeEvent is retained for backward compatibility.
  // In strict mode it is derived from the canonical sellback signal
  // Furnace.LockSoldToFurnace (written by the Furnace mapping), not from MarketRouter.
  BonusTargetEscrow,
  BonusTargetEscrowEvent,
  BonusTargetEscrowExecutedEvent,
  BonusTargetEscrowAutoFurnaceExecutedEvent,
  MarketSettlementKeeper,
  MarketSettlementKeeperSetEvent,
  MarketRouterParams,
  BonusTargetEscrowParamsChangedEvent,
  TxFurnaceEnter,
  VeLock,
} from '../generated/schema';

import { eventId } from '../utils/id';
import { saveActivityItem } from '../utils/activity';
import { loadOrCreateProtocol, setBytesIfZero, ZERO_ADDRESS } from '../utils/protocol';
import { loadOrCreateUser } from '../utils/user';
import { currentVeWei } from '../utils/ve';

const ZERO = BigInt.fromI32(0);
const BPS = BigInt.fromI32(10000);
const UNKNOWN_LISTING_PRICE_BPS = BigInt.fromString('1000000000');

const MARKET_ROUTER_PARAMS_ID = 'current';
const UNKNOWN_MAX_DISCOUNT_BPS = -1;

function isLocalNetwork(): bool {
  return dataSource.network() == 'local';
}

function isZeroAddress(addr: Address): bool {
  return addr.toHexString() == ZERO_ADDRESS.toHexString();
}

function txFurnaceEnterIdByLog(txHash: Bytes, logIndex: BigInt): string {
  return txHash.toHexString() + '-' + logIndex.toString();
}

// keccak256("FurnaceEnter(address,uint8,uint256,uint256,uint256,uint256)")
// (Furnace.FurnaceEnter: indexed address user, uint8 mode, uint256 ethIn,
// uint256 principalClaim, uint256 bonusClaim, uint256 tokenId.)
const FURNACE_ENTER_SIG = Bytes.fromHexString(
  '0x7f7f0de17f3500a1420b9cdc65ea622e20871e0abe71d5192560052b4999961f',
) as Bytes;

// Find the largest FurnaceEnter logIndex strictly less than `beforeLogIndex`
// emitted by the canonical Furnace contract. Returns -1 when no preceding
// FurnaceEnter log exists in this receipt. Pairs an auto-furnace executing
// event with its sibling FurnaceEnter inside the same transaction so the
// MarketRouter execution row can be enriched with the actual minted token id
// even when several FurnaceEnter logs share the tx.
function findPrecedingFurnaceEnterLogIndex(
  receipt: ethereum.TransactionReceipt | null,
  furnaceAddr: Bytes,
  beforeLogIndex: BigInt,
): BigInt {
  if (receipt == null) return BigInt.fromI32(-1);
  const logs = (receipt as ethereum.TransactionReceipt).logs;
  const requireEmitter = furnaceAddr.toHexString() != ZERO_ADDRESS.toHexString();
  let best: BigInt = BigInt.fromI32(-1);
  for (let i = 0; i < logs.length; i++) {
    const log = logs[i];
    if (log.logIndex.ge(beforeLogIndex)) continue;
    if (log.topics.length == 0) continue;
    if (log.topics[0].toHexString() != FURNACE_ENTER_SIG.toHexString()) continue;
    if (requireEmitter && log.address.toHexString() != furnaceAddr.toHexString()) continue;
    if (best.lt(log.logIndex)) best = log.logIndex;
  }
  return best;
}

// Best-effort resolve the VeClaimNFT address used by this MarketRouter.
// - Prefer the cached Protocol.veClaimNft address when known.
// - Otherwise, resolve deterministically via MarketRouter.ve() (non-local networks only).
function resolveVeClaimNftAddress(cachedVe: Bytes, router: Address): Address {
  const cached = Address.fromBytes(cachedVe);
  if (!isZeroAddress(cached)) return cached;

  if (isLocalNetwork()) return ZERO_ADDRESS;

  const mr = MarketRouter.bind(router);
  const res = mr.try_ve();
  if (res.reverted) return ZERO_ADDRESS;
  return res.value;
}

// If VeLock state is missing (common when indexing starts mid-history), hydrate
// the canonical lock parameters from VeClaimNFT.getLockInfo(tokenId) so that
// MarketListing.priceBps can be computed correctly.
function hydrateVeLockIfNeeded(lock: VeLock, tokenId: BigInt, now: BigInt, veAddr: Address): void {
  if (isLocalNetwork()) return;
  if (isZeroAddress(veAddr)) return;

  // Only hydrate when the lock appears uninitialized.
  if (!lock.amountWei.equals(ZERO) || !lock.lockEnd.equals(ZERO)) return;

  const ve = VeClaimNFTContract.bind(veAddr);
  const info = ve.try_getLockInfo(tokenId);
  if (info.reverted) return;

  lock.amountWei = info.value.value0;
  lock.lockEnd = info.value.value1;
  lock.autoMax = info.value.value2;

  lock.updatedAt = now;
  lock.currentVeWei = currentVeWei(lock.amountWei, lock.lockEnd, now, lock.autoMax);
  lock.save();
}

function computeDiscountBps(price: BigInt, principal: BigInt): i32 {
  // discount granularity is limited. Rounding is always toward zero (floor).
  // ANALYSIS: This matches the on-chain computation which also uses integer
  // division. The truncation is symmetric with the contract behavior.
  // For very small principals (< 10000 wei), bps resolution is limited
  // but this is an extreme edge case with negligible economic impact.
  // If principal is zero, define discount as 0 bps (unknown / not meaningful).
  if (principal.equals(ZERO)) return 0;
  // discountBps = floor((1 - price / principal) * 10_000). Premiums clamp to 0.
  if (price.ge(principal)) return 0;
  const diff = principal.minus(price);
  const bps = diff.times(BPS).div(principal);
  // Defensive clamp.
  const asI32 = bps.toI32();
  if (asI32 < 0) return 0;
  if (asI32 > 10000) return 10000;
  return asI32;
}

function computeOfferPriceBpsFromDiscount(discountBps: i32): BigInt {
  // priceBps = 10_000 - discountBps
  let d = discountBps;
  if (d < 0) d = 0;
  if (d > 10000) d = 10000;
  return BigInt.fromI32(10000 - d);
}

function computeOfferPriceBpsFromTargetBonus(targetBonusBps: i32): BigInt {
  // Onchain derives discountBps from the bonus target:
  //   discountBps = floor(targetBonusBps * 10_000 / (10_000 + targetBonusBps))
  // And the effective offer price factor is:
  //   priceBps = 10_000 - discountBps
  //
  // IMPORTANT: Do not use floor(10_000^2 / (10_000 + targetBonusBps)). That differs by 1 bps
  // for most values due to integer division rounding.
  let tb = targetBonusBps;
  if (tb < 0) tb = 0;
  const bonus = BigInt.fromI32(tb);
  const discount = bonus.times(BPS).div(BPS.plus(bonus));
  return BPS.minus(discount);
}

function computeListingPriceBps(minClaimOut: BigInt, lockAmountWei: BigInt): BigInt {
  // priceBps = floor(minClaimOutWei * 10_000 / lockAmountWei)
  if (lockAmountWei.equals(ZERO)) return ZERO;
  return minClaimOut.times(BPS).div(lockAmountWei);
}

/// Realized bonus ratio expressed in bps relative to **principalClaim**, the gross
/// amount the buyer paid in. This is the ratio used by the on-chain
/// `MarketRouter._prepareAutoFurnaceExecution.BonusTargetNotMet` gate
/// (`floor(bonus * BPS_DENOM / principalClaim) >= targetBonusBps`).
///
/// Note for downstream consumers: this is NOT the bps ratio against `principalEff`
/// (the duration-weighted effective principal that feeds the Furnace AMM). For a
/// near-MAX duration the two ratios converge; for shorter durations they diverge
/// and `bonusBpsVsPrincipalClaim` will read lower than the bonus rate on the AMM
/// curve. The on-chain `BonusPaid` event carries both `principalClaim` and
/// `principalEff` — consumers needing the AMM-curve ratio should compute it from
/// those fields.
function computeBonusBps(bonus: BigInt, principal: BigInt): i32 {
  if (principal.equals(ZERO)) return 0;
  const raw = bonus.times(BigInt.fromI32(10000)).div(principal).toI32();
  if (raw < 0) return 0;
  return raw;
}

function loadOrCreateVeLockForMarket(tokenId: BigInt, owner: Address, now: BigInt): VeLock {
  const id = tokenId.toString();
  let l = VeLock.load(id);
  if (l == null) {
    const u = loadOrCreateUser(owner);
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

function loadOrCreateListing(tokenId: BigInt, seller: Address, now: BigInt): MarketListing {
  const id = tokenId.toString();
  let listing = MarketListing.load(id);
  if (listing == null) {
    const sellerUser = loadOrCreateUser(seller);
    listing = new MarketListing(id);
    listing.tokenId = tokenId;
    listing.lock = id;
    listing.seller = sellerUser.id;
    listing.minClaimOutWei = ZERO;
    listing.priceBps = ZERO;
    listing.listedAtTime = now;
    listing.expiresAtTime = ZERO;
    listing.active = false;
    listing.updatedAt = now;
    listing.save();
  }
  return listing as MarketListing;
}

function loadOrCreateOffer(offerId: BigInt, buyer: Address, now: BigInt): BonusTargetEscrow {
  const id = offerId.toString();
  let o = BonusTargetEscrow.load(id);
  if (o == null) {
    const buyerUser = loadOrCreateUser(buyer);
    o = new BonusTargetEscrow(id);
    o.offerId = offerId;
    o.buyer = buyerUser.id;
    o.discountBps = 0;

    // Normalized bid price (bps). 0 means unknown until created/configured events arrive.
    o.priceBps = ZERO;
    // Compatibility field: null when unknown.
    o.minLockSizeWei = null;
    o.budgetClaimWei = ZERO;
    o.fundsRemainingWei = ZERO;
    o.createdAt = now;
    o.expiresAt = ZERO;
    o.active = false;

    // AutoFill settings (null means unknown / not applicable)
    o.durationSeconds = null;
    o.createAutoMax = false;
    o.destinationLockId = null;
    o.destinationLock = null;

    o.targetBonusBps = 0;
    o.slippageBps = 0;
    o.updatedAt = now;
    o.save();
  }
  return o as BonusTargetEscrow;
}

function closeOfferAfterExecution(offerId: BigInt, buyer: Address, now: BigInt): BonusTargetEscrow {
  const o = loadOrCreateOffer(offerId, buyer, now);
  const buyerUser = loadOrCreateUser(buyer);

  // Idempotency guard: if the offer was already closed by a prior handler in the
  // same tx (e.g., both Executed and AutoFurnaceExecuted fire), skip redundant write.
  if (!o.active && o.fundsRemainingWei !== null && (o.fundsRemainingWei as BigInt).equals(ZERO)) {
    return o;
  }

  // If partial fills are possible, this should deduct claimInWei instead.
  // The current pattern closes the offer on every execution regardless of partial state.
  //
  // In v1.0.0, BonusTargetEscrowExecuted fires once per execution and each execution
  // fully drains the escrow, so the handler closes the offer unconditionally.
  o.buyer = buyerUser.id;
  o.fundsRemainingWei = ZERO;
  o.active = false;
  o.updatedAt = now;
  o.save();

  return o as BonusTargetEscrow;
}

function resolveExecutedFurnaceTokenId(
  txHash: Bytes,
  emittedFurnaceTokenId: BigInt,
  receipt: ethereum.TransactionReceipt | null,
  furnaceAddr: Bytes,
  beforeLogIndex: BigInt,
): BigInt {
  if (emittedFurnaceTokenId.notEqual(ZERO)) {
    return emittedFurnaceTokenId;
  }

  const idx = findPrecedingFurnaceEnterLogIndex(receipt, furnaceAddr, beforeLogIndex);
  if (idx.lt(ZERO)) return ZERO;

  const joinId = txFurnaceEnterIdByLog(txHash, idx);
  const join = TxFurnaceEnter.load(joinId);
  if (join != null) {
    return (join as TxFurnaceEnter).tokenId;
  }

  return ZERO;
}

function loadOrCreateMarketRouterParams(): MarketRouterParams {
  let p = MarketRouterParams.load(MARKET_ROUTER_PARAMS_ID);
  if (p == null) {
    p = new MarketRouterParams(MARKET_ROUTER_PARAMS_ID);
    p.updatedAt = ZERO;
    // Default to 0; use updatedAt==0 and maxDiscount==-1 as the only "unknown" sentinels.
    // (minBudget itself may legitimately be 0 onchain.)
    p.minBonusTargetEscrowBudgetClaimWei = ZERO;
    // -1 is a sentinel for "unknown" (onchain value is uint).
    p.maxBonusTargetEscrowDiscountBps = UNKNOWN_MAX_DISCOUNT_BPS;
    p.save();
  } else {
    // Backfill fields when upgrading a running subgraph store.
    let didBackfill = false;

    if (p.get('updatedAt') == null) {
      p.updatedAt = ZERO;
      didBackfill = true;
    }
    if (p.get('minBonusTargetEscrowBudgetClaimWei') == null) {
      p.minBonusTargetEscrowBudgetClaimWei = ZERO;
      didBackfill = true;
    }
    if (p.get('maxBonusTargetEscrowDiscountBps') == null) {
      p.maxBonusTargetEscrowDiscountBps = UNKNOWN_MAX_DISCOUNT_BPS;
      didBackfill = true;
    }

    if (didBackfill) {
      p.save();
    }
  }
  return p as MarketRouterParams;
}

// Best-effort hydrate global offer spam controls from onchain storage.
// This only runs once per subgraph store (per network), and is skipped on local networks
// where Anvil may prune old block state.
function maybeSnapshotMarketRouterParams(router: Address, ts: BigInt): void {
  if (isLocalNetwork()) return;

  const p = loadOrCreateMarketRouterParams();

  // Fast-path: already populated.
  if (p.maxBonusTargetEscrowDiscountBps != UNKNOWN_MAX_DISCOUNT_BPS && !p.updatedAt.equals(ZERO)) {
    return;
  }

  const mr = MarketRouter.bind(router);
  const minRes = mr.try_minBonusTargetEscrowBudget();
  const maxRes = mr.try_maxBonusTargetEscrowDiscountBps();
  if (minRes.reverted || maxRes.reverted) return;

  p.updatedAt = ts;
  p.minBonusTargetEscrowBudgetClaimWei = minRes.value;
  p.maxBonusTargetEscrowDiscountBps = maxRes.value.toI32();
  p.save();
}
function createBonusTargetEscrowEvent(
  offerId: string,
  kind: string,
  timestamp: BigInt,
  txHash: Bytes,
  id: string,
): void {
  const e = new BonusTargetEscrowEvent(id);
  e.offer = offerId;
  e.kind = kind;
  e.timestamp = timestamp;
  e.txHash = txHash;
  e.save();
}

export function handleTradingPausedChanged(event: TradingPausedChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.tradingPaused = event.params.paused;
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);
}

export function handleSettlementKeeperSet(event: SettlementKeeperSet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const id = eventId(event);
  const keeper = loadOrCreateUser(event.params.keeper);

  let k = MarketSettlementKeeper.load(keeper.id);
  if (k == null) {
    k = new MarketSettlementKeeper(keeper.id);
    k.keeper = keeper.id;
    k.allowed = false;
    k.updatedAt = event.block.timestamp;
  }

  k.allowed = event.params.allowed;
  k.updatedAt = event.block.timestamp;
  k.save();

  const e = new MarketSettlementKeeperSetEvent(id);
  e.keeper = keeper.id;
  e.allowed = event.params.allowed;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleBonusTargetEscrowParamsChanged(event: BonusTargetEscrowParamsChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  // Update current params snapshot.
  const params = loadOrCreateMarketRouterParams();
  params.updatedAt = now;
  params.minBonusTargetEscrowBudgetClaimWei = event.params.newMinBudget;
  params.maxBonusTargetEscrowDiscountBps = event.params.newMaxDiscountBps.toI32();
  params.save();

  const e = new BonusTargetEscrowParamsChangedEvent(id);
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.oldMinBudgetClaimWei = event.params.oldMinBudget;
  e.newMinBudgetClaimWei = event.params.newMinBudget;
  e.oldMaxDiscountBps = event.params.oldMaxDiscountBps.toI32();
  e.newMaxDiscountBps = event.params.newMaxDiscountBps.toI32();
  e.save();
}
export function handleLockListed(event: LockListed): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);

  const veAddr = resolveVeClaimNftAddress(protocol.veClaimNft, event.address);
  // Cache the resolved ve address for downstream mappings.
  if (isZeroAddress(Address.fromBytes(protocol.veClaimNft)) && !isZeroAddress(veAddr)) {
    protocol.veClaimNft = veAddr;
  }
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const seller = loadOrCreateUser(event.params.seller);

  const lock = loadOrCreateVeLockForMarket(event.params.tokenId, event.params.seller, now);
  hydrateVeLockIfNeeded(lock, event.params.tokenId, now, veAddr);

  lock.listed = true;
  lock.updatedAt = now;
  lock.save();

  const listing = loadOrCreateListing(event.params.tokenId, event.params.seller, now);
  listing.lock = lock.id;
  listing.seller = seller.id;
  listing.minClaimOutWei = event.params.minClaimOut;

  let priceBps = computeListingPriceBps(event.params.minClaimOut, lock.amountWei);
  // If lock.amountWei is unknown, avoid poisoning orderbook sorting by treating it as "very expensive".
  if (!event.params.minClaimOut.equals(ZERO) && lock.amountWei.equals(ZERO)) {
    priceBps = UNKNOWN_LISTING_PRICE_BPS;
  }
  listing.priceBps = priceBps;
  listing.listedAtTime = event.params.listedAtTime;
  listing.expiresAtTime = event.params.expiresAtTime;
  listing.active = true;
  listing.updatedAt = now;
  listing.save();

  const e = new MarketLockListedEvent(id);
  e.tokenId = event.params.tokenId;
  e.seller = seller.id;
  e.minClaimOutWei = event.params.minClaimOut;
  e.listedAtTime = event.params.listedAtTime;
  e.expiresAtTime = event.params.expiresAtTime;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLockDelisted(event: LockDelisted): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  // Snapshot the last known listing price (if any) for analytics/debug.
  let priceBefore: BigInt | null = null;
  const listingBefore = MarketListing.load(event.params.tokenId.toString());
  if (listingBefore != null) {
    priceBefore = listingBefore.minClaimOutWei;
    // Avoid writing a misleading 0 price for unknown listings.
    if (priceBefore.equals(ZERO)) priceBefore = null;
  }

  const listing = loadOrCreateListing(event.params.tokenId, event.params.seller, now);
  listing.active = false;
  listing.updatedAt = now;
  listing.save();

  const lock = loadOrCreateVeLockForMarket(event.params.tokenId, event.params.seller, now);
  lock.listed = false;
  lock.updatedAt = now;
  lock.save();

  const seller = loadOrCreateUser(event.params.seller);

  const e = new MarketLockDelistedEvent(id);
  e.tokenId = event.params.tokenId;
  e.seller = seller.id;
  e.reason = event.params.reason;
  e.minClaimOutWei = priceBefore;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}

// ListingSettled event handler (Furnace settled a listing)
export function handleListingSettled(event: ListingSettled): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const seller = loadOrCreateUser(event.params.seller);

  // Update listing state (mark inactive)
  const listing = loadOrCreateListing(event.params.tokenId, event.params.seller, now);
  listing.active = false;
  listing.updatedAt = now;
  listing.save();

  // Update lock state (not listed)
  const lock = loadOrCreateVeLockForMarket(event.params.tokenId, event.params.seller, now);
  lock.listed = false;
  lock.updatedAt = now;
  lock.save();

  // Create the settled event entity
  const e = new ListingSettledEvent(id);
  e.tokenId = event.params.tokenId;
  e.seller = seller.id;
  e.claimOutWei = event.params.claimOut;
  e.penaltyWei = event.params.penalty;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();

  // Activity feed item
  const a = new ActivityItem(id);
  a.kind = 'LISTING_SETTLED';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = event.params.tokenId;
  a.user = seller.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.claimOut;
  saveActivityItem(a);
}

export function handleMarketSellToFurnace(event: MarketSellToFurnace): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const seller = loadOrCreateUser(event.params.seller);

  // If a stale listing exists for this tokenId, mark it inactive to avoid UI/keeper confusion.
  const listingBefore = MarketListing.load(event.params.tokenId.toString());
  if (listingBefore != null) {
    listingBefore.active = false;
    listingBefore.updatedAt = now;
    listingBefore.save();
  }

  const lock = loadOrCreateVeLockForMarket(event.params.tokenId, event.params.seller, now);
  lock.listed = false;
  lock.updatedAt = now;
  lock.save();

  const e = new MarketSellToFurnaceEvent(id);
  e.tokenId = event.params.tokenId;
  e.seller = seller.id;
  e.minClaimOutWei = event.params.minClaimOut;
  e.deadline = event.params.deadline;
  e.claimOutWei = event.params.claimOut;
  e.timestamp = now;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();

  const a = new ActivityItem(id);
  a.kind = 'MARKET_SELL_TO_FURNACE';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = event.params.tokenId;
  a.user = seller.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.claimOut;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowCreated(event: BonusTargetEscrowCreated): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);

  const offerId = event.params.escrowId.toString();
  let o = BonusTargetEscrow.load(offerId);
  if (o == null) {
    o = new BonusTargetEscrow(offerId);
    o.targetBonusBps = 0;
    o.slippageBps = 0;
  }

  o.offerId = event.params.escrowId;
  o.buyer = buyer.id;
  o.discountBps = event.params.discountBps.toI32();

  // Default pricing model is discount-based until bonus-target config arrives.
  o.priceBps = computeOfferPriceBpsFromDiscount(o.discountBps);

  // Compatibility field (minLockSizeWei) is not used by AutoFill offers.
  o.minLockSizeWei = null;

  o.budgetClaimWei = event.params.budgetClaim;
  o.fundsRemainingWei = event.params.budgetClaim;
  o.createdAt = event.params.createdAt;
  o.updatedAt = now;
  o.active = true;

  // AutoFill settings
  o.durationSeconds = event.params.durationSeconds;
  o.createAutoMax = event.params.createAutoMax;
  // expiry timestamp (seconds)
  o.expiresAt = event.params.expiresAt;

  const dest = event.params.destinationLockId;
  if (dest.equals(ZERO)) {
    o.destinationLockId = null;
    o.destinationLock = null;
  } else {
    o.destinationLockId = dest;
    o.destinationLock = dest.toString();
  }

  o.save();

  createBonusTargetEscrowEvent(offerId, 'CREATED', now, event.transaction.hash, id);

  const a = new ActivityItem(id);
  a.kind = 'GLOBAL_OFFER_CREATED';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = null;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.budgetClaim;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowExpired(event: BonusTargetEscrowExpired): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);

  const offerId = event.params.escrowId.toString();
  const offer = loadOrCreateOffer(event.params.escrowId, event.params.buyer, now);
  offer.active = false;
  offer.fundsRemainingWei = ZERO;
  offer.updatedAt = now;
  offer.save();

  createBonusTargetEscrowEvent(offerId, 'EXPIRED', now, event.transaction.hash, id);

  const a = new ActivityItem(id);
  a.kind = 'AUTO_FILL_OFFER_EXPIRED';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = null;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.refundClaim;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowExpiryExtended(
  event: BonusTargetEscrowExpiryExtended,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);

  const offerId = event.params.escrowId.toString();
  const offer = loadOrCreateOffer(event.params.escrowId, event.params.buyer, now);
  if (event.params.newExpiresAt.gt(now)) {
    offer.active = true;
  } else {
    offer.active = false;
  }
  offer.expiresAt = event.params.newExpiresAt;
  offer.updatedAt = now;
  offer.save();

  createBonusTargetEscrowEvent(offerId, 'EXPIRY_EXTENDED', now, event.transaction.hash, id);

  const a = new ActivityItem(id);
  a.kind = 'AUTO_FILL_OFFER_EXPIRY_EXTENDED';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = null;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = null;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowCancelled(event: BonusTargetEscrowCancelled): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);

  const o = loadOrCreateOffer(event.params.escrowId, event.params.buyer, now);
  o.buyer = buyer.id;
  o.active = false;
  o.fundsRemainingWei = ZERO;
  o.updatedAt = now;
  o.save();

  createBonusTargetEscrowEvent(o.id, 'CANCELLED', now, event.transaction.hash, id);

  const a = new ActivityItem(id);
  a.kind = 'GLOBAL_OFFER_CANCELLED';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = null;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.refundClaim;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowConfigured(event: BonusTargetEscrowConfigured): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);

  const o = loadOrCreateOffer(event.params.escrowId, event.params.buyer, now);
  o.buyer = buyer.id;
  o.targetBonusBps = event.params.targetBonusBps.toI32();
  // Bonus-target offers price in terms of targetBonusBps (canonical).
  o.priceBps = computeOfferPriceBpsFromTargetBonus(o.targetBonusBps);

  // slippageBps is included in the event for spec/onchain alignment.
  o.slippageBps = event.params.slippageBps.toI32();

  o.updatedAt = now;
  o.save();

  createBonusTargetEscrowEvent(o.id, 'BONUS_CONFIGURED', now, event.transaction.hash, id);

  const a = new ActivityItem(id);
  a.kind = 'GLOBAL_OFFER_CONFIGURED';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = null;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = null;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowExecuted(event: BonusTargetEscrowExecuted): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);
  const o = closeOfferAfterExecution(event.params.escrowId, event.params.buyer, now);

  // Canonical generic offer-history receipt. AUTO_FURNACE_EXECUTED remains the
  // same-tx companion row for detail and compatibility consumers.
  createBonusTargetEscrowEvent(o.id, 'FILLED', now, event.transaction.hash, id);

  const exec = new BonusTargetEscrowExecutedEvent(id);
  exec.offer = o.id;
  exec.buyer = buyer.id;
  exec.claimInWei = event.params.claimIn;
  exec.principalClaimWei = event.params.principalClaim;
  exec.bonusClaimWei = event.params.bonusClaim;
  exec.veOutWei = event.params.veOut;
  const bonusBpsVsPrincipalClaim = computeBonusBps(
    event.params.bonusClaim,
    event.params.principalClaim,
  );
  exec.bonusBpsVsPrincipalClaim = bonusBpsVsPrincipalClaim;
  exec.routeTokenId = event.params.routeTokenId;

  const furnaceTokenId = resolveExecutedFurnaceTokenId(
    event.transaction.hash,
    event.params.furnaceTokenId,
    event.receipt,
    protocol.furnace,
    event.logIndex,
  );
  exec.furnaceTokenId = furnaceTokenId.equals(ZERO) ? null : furnaceTokenId;

  exec.timestamp = now;
  exec.blockNumber = event.block.number;
  exec.txHash = event.transaction.hash;
  exec.save();

  // Defensive: if the executed escrow targeted a specific lock, ensure the
  // listing and lock.listed flags are consistent. Normally handled by the
  // separate LockDelisted event, but guards against ordering/gap issues.
  if (event.params.routeTokenId.notEqual(ZERO)) {
    const tokenIdStr = event.params.routeTokenId.toString();
    const listing = MarketListing.load(tokenIdStr);
    if (listing !== null && listing.active) {
      listing.active = false;
      listing.updatedAt = now;
      listing.save();
    }
    const lock = VeLock.load(tokenIdStr);
    if (lock !== null && lock.listed) {
      lock.listed = false;
      lock.updatedAt = now;
      lock.save();
    }
  }

  // Activity feed entry for direct escrow fills (parity with AutoFurnaceExecuted).
  let tokenForActivity: BigInt | null = null;
  if (exec.furnaceTokenId !== null) {
    tokenForActivity = exec.furnaceTokenId;
  } else if (event.params.routeTokenId.notEqual(ZERO)) {
    tokenForActivity = event.params.routeTokenId;
  }

  const a = new ActivityItem(id);
  a.kind = 'GLOBAL_OFFER_EVENT';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = tokenForActivity;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.claimIn;
  saveActivityItem(a);
}

export function handleBonusTargetEscrowAutoFurnaceExecuted(
  event: BonusTargetEscrowAutoFurnaceExecuted,
): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.marketRouter = setBytesIfZero(protocol.marketRouter, event.address);
  protocol.save();

  // Hydrate global offer spam controls for backend/UI parity (one-time per store).
  maybeSnapshotMarketRouterParams(event.address, event.block.timestamp);

  const now = event.block.timestamp;
  const id = eventId(event);

  const buyer = loadOrCreateUser(event.params.buyer);

  const o = closeOfferAfterExecution(event.params.escrowId, event.params.buyer, now);

  createBonusTargetEscrowEvent(o.id, 'AUTO_FURNACE_EXECUTED', now, event.transaction.hash, id);

  // Detailed auto-furnace receipt retained for backward compatibility.
  // The canonical generic execution receipt is BonusTargetEscrowExecutedEvent.
  const exec = new BonusTargetEscrowAutoFurnaceExecutedEvent(id);
  exec.offer = o.id;
  exec.buyer = buyer.id;
  exec.claimInWei = event.params.claimIn;
  exec.principalClaimWei = event.params.principalClaim;
  exec.bonusClaimWei = event.params.bonusClaim;
  exec.veOutWei = event.params.veOut;
  const bonusBpsVsPrincipalClaim = computeBonusBps(
    event.params.bonusClaim,
    event.params.principalClaim,
  );
  exec.bonusBpsVsPrincipalClaim = bonusBpsVsPrincipalClaim;
  exec.routeTokenId = event.params.routeTokenId;

  const furnaceTokenId = resolveExecutedFurnaceTokenId(
    event.transaction.hash,
    event.params.furnaceTokenId,
    event.receipt,
    protocol.furnace,
    event.logIndex,
  );
  exec.furnaceTokenId = furnaceTokenId.equals(ZERO) ? null : furnaceTokenId;

  exec.timestamp = now;
  exec.blockNumber = event.block.number;
  exec.txHash = event.transaction.hash;
  exec.save();

  // Prefer the actual Furnace token id (canonical flow). Fall back to the routed token id.
  let tokenForActivity: BigInt | null = null;
  if (!furnaceTokenId.equals(ZERO)) {
    tokenForActivity = furnaceTokenId;
  } else if (event.params.routeTokenId.notEqual(ZERO)) {
    tokenForActivity = event.params.routeTokenId;
  }

  const a = new ActivityItem(id);
  a.kind = 'GLOBAL_OFFER_EVENT';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.reignId = null;
  a.tokenId = tokenForActivity;
  a.user = buyer.id;
  a.otherUser = null;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.claimIn;
  saveActivityItem(a);
}
