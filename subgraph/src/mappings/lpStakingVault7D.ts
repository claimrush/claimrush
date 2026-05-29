import { Address, BigInt, Bytes, dataSource } from "@graphprotocol/graph-ts";

import {
  AutoCompoundConfigured,
  AutoCompoundPaused,
  AutoCompoundUnpaused,
  AccountedRewardBalanceClamped,
  DelegationSessionUsed,
  HarvestKeeperSet,
  HarvestMinClaimOutIgnored,
  LpFeesHarvestedToRewards,
  LpRewardsClaimed,
  LpRewardsLocked,
  LpRewardsNotified,
  LpStaked,
  LpUnbondStarted,
  LpUnbondWithdrawn,
  MinCompoundRewardSet,
  MinHarvestClaimFloorSet,
  NotifyAmountDivergence,
  OwnershipTransferStarted,
  OwnershipTransferred,
} from "../generated/LpStakingVault7D/LpStakingVault7D";

import {
  AutoCompoundConfiguredEvent,
  AutoCompoundPausedEvent,
  AutoCompoundUnpausedEvent,
  HarvestKeeper,
  HarvestKeeperSetEvent,
  LpAccountedRewardBalanceClampedEvent,
  LpFeesHarvestedToRewardsEvent,
  LpHarvestMinClaimOutIgnoredEvent,
  LpMinCompoundRewardSetEvent,
  LpMinHarvestClaimFloorSetEvent,
  LpNotifyAmountDivergenceEvent,
  LpOwnershipTransferStartedEvent,
  LpOwnershipTransferredEvent,
  LpRewardsClaimedEvent,
  LpRewardsLockedEvent,
  LpRewardsNotifiedEvent,
  LpStakedEvent,
  LpUnbondStartedEvent,
  LpUnbondWithdrawnEvent,
} from "../generated/schema";

import { eventId } from "../utils/id";
import { recordDelegationSessionUsed } from "../utils/delegation";
import { loadOrCreateUser } from "../utils/user";
import { recordLpEventForApr } from "../utils/aprSnapshot";
import { refreshTokenPricingSnapshot } from "../utils/tokenPricingSnapshot";
import { ZERO_ADDRESS, loadOrCreateProtocol } from "../utils/protocol";

const COMPOUND_FOR_SELECTOR = "0x22e65764";
const COMPOUND_FOR_MANY_SELECTOR = "0xd4c3d93b";

function isAutoCompoundTransaction(input: Bytes): boolean {
  const selector = input.toHexString().slice(0, 10);
  return selector == COMPOUND_FOR_SELECTOR || selector == COMPOUND_FOR_MANY_SELECTOR;
}

export function handleAutoCompoundConfigured(event: AutoCompoundConfigured): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new AutoCompoundConfiguredEvent(id);
  e.user = user.id;
  e.enabled = event.params.enabled;
  e.tokenId = event.params.tokenId;
  e.durationSeconds = event.params.durationSeconds;
  e.maxSlippageBps = event.params.maxSlippageBps;
  e.minRewardToCompoundWei = event.params.minRewardToCompound;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleAutoCompoundPaused(event: AutoCompoundPaused): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new AutoCompoundPausedEvent(id);
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.reasonCode = event.params.reasonCode;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleAutoCompoundUnpaused(event: AutoCompoundUnpaused): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new AutoCompoundUnpausedEvent(id);
  e.user = user.id;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleHarvestKeeperSet(event: HarvestKeeperSet): void {
  const keeper = loadOrCreateUser(event.params.keeper);
  const keeperId = keeper.id;

  let state = HarvestKeeper.load(keeperId);
  if (state == null) {
    state = new HarvestKeeper(keeperId);
    state.keeper = keeperId;
  }
  state.allowed = event.params.allowed;
  state.updatedAt = event.block.timestamp;
  state.save();

  const id = eventId(event);
  const e = new HarvestKeeperSetEvent(id);
  e.keeper = keeperId;
  e.allowed = event.params.allowed;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleMinCompoundRewardSet(event: MinCompoundRewardSet): void {
  const id = eventId(event);
  const e = new LpMinCompoundRewardSetEvent(id);
  e.oldFloorWei = event.params.oldFloor;
  e.newFloorWei = event.params.newFloor;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleMinHarvestClaimFloorSet(event: MinHarvestClaimFloorSet): void {
  const id = eventId(event);
  const e = new LpMinHarvestClaimFloorSetEvent(id);
  e.oldFloorWei = event.params.oldFloor;
  e.newFloorWei = event.params.newFloor;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleNotifyAmountDivergence(event: NotifyAmountDivergence): void {
  const id = eventId(event);
  const e = new LpNotifyAmountDivergenceEvent(id);
  e.declaredWei = event.params.declared;
  e.actualDeltaWei = event.params.actualDelta;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleAccountedRewardBalanceClamped(event: AccountedRewardBalanceClamped): void {
  const id = eventId(event);
  const e = new LpAccountedRewardBalanceClampedEvent(id);
  e.requestedWei = event.params.requested;
  e.availableWei = event.params.available;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleHarvestMinClaimOutIgnored(event: HarvestMinClaimOutIgnored): void {
  const id = eventId(event);
  const e = new LpHarvestMinClaimOutIgnoredEvent(id);
  e.minClaimOutWei = event.params.minClaimOut;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleOwnershipTransferStarted(event: OwnershipTransferStarted): void {
  const id = eventId(event);
  const previousOwner = loadOrCreateUser(event.params.previousOwner);
  const newOwner = loadOrCreateUser(event.params.newOwner);

  const e = new LpOwnershipTransferStartedEvent(id);
  e.previousOwner = previousOwner.id;
  e.newOwner = newOwner.id;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleOwnershipTransferred(event: OwnershipTransferred): void {
  const id = eventId(event);
  const previousOwner = loadOrCreateUser(event.params.previousOwner);
  const newOwner = loadOrCreateUser(event.params.newOwner);

  const e = new LpOwnershipTransferredEvent(id);
  e.previousOwner = previousOwner.id;
  e.newOwner = newOwner.id;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLpStaked(event: LpStaked): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new LpStakedEvent(id);
  e.user = user.id;
  e.amount = event.params.amount;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  // `totalStaked` just moved; re-snapshot the LP TVL into the current hour
  // bucket so the rolling 24h average tracks the new denominator.
  refreshLpTvlAfterStakeChange(event.block.number, event.block.timestamp);
}

export function handleLpUnbondStarted(event: LpUnbondStarted): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new LpUnbondStartedEvent(id);
  e.user = user.id;
  e.unbondId = event.params.unbondId;
  e.amount = event.params.amount;
  e.unlockTime = event.params.unlockTime;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  // beginUnbond decrements `totalStaked` (see LpStakingVault7D.beginUnbond) —
  // re-snapshot in the same way as stake.
  refreshLpTvlAfterStakeChange(event.block.number, event.block.timestamp);
}

/**
 * Shared TVL re-snapshot path for stake / beginUnbond. Refreshes the pricing
 * singleton first (claimEthTwap, ethUsd) so the APR populator reads
 * consistent stocks and flows at the same block.
 */
function refreshLpTvlAfterStakeChange(blockNumber: BigInt, blockTimestamp: BigInt): void {
  const protocol = loadOrCreateProtocol(blockNumber);
  const veNftBytes = protocol.veClaimNft;
  if (veNftBytes.toHexString() != ZERO_ADDRESS.toHexString()) {
    refreshTokenPricingSnapshot(
      Address.fromBytes(veNftBytes as Bytes),
      blockNumber,
      blockTimestamp,
    );
  }
  recordLpEventForApr(dataSource.address(), blockNumber, blockTimestamp, BigInt.zero());
}

export function handleLpUnbondWithdrawn(event: LpUnbondWithdrawn): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new LpUnbondWithdrawnEvent(id);
  e.user = user.id;
  e.unbondId = event.params.unbondId;
  e.amount = event.params.amount;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLpRewardsNotified(event: LpRewardsNotified): void {
  const id = eventId(event);

  const e = new LpRewardsNotifiedEvent(id);
  e.amountClaim = event.params.amountClaim;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  // Flow source for the APR numerator. Refresh pricing first so the APR
  // recompute reads claimUsd / ethUsd at the same block as the reward.
  const protocol = loadOrCreateProtocol(event.block.number);
  if (protocol.veClaimNft.toHexString() != ZERO_ADDRESS.toHexString()) {
    refreshTokenPricingSnapshot(
      Address.fromBytes(protocol.veClaimNft as Bytes),
      event.block.number,
      event.block.timestamp,
    );
  }
  recordLpEventForApr(
    dataSource.address(),
    event.block.number,
    event.block.timestamp,
    event.params.amountClaim,
  );
}

export function handleLpRewardsClaimed(event: LpRewardsClaimed): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new LpRewardsClaimedEvent(id);
  e.user = user.id;
  e.amountClaim = event.params.amountClaim;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLpRewardsLocked(event: LpRewardsLocked): void {
  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new LpRewardsLockedEvent(id);
  e.user = user.id;
  e.amountClaim = event.params.amountClaim;
  e.principalClaim = event.params.principalClaim;
  e.bonusClaim = event.params.bonusClaim;
  e.tokenId = event.params.tokenId;
  e.autoCompounded = isAutoCompoundTransaction(event.transaction.input);
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleLpFeesHarvestedToRewards(event: LpFeesHarvestedToRewards): void {
  const id = eventId(event);
  const caller = loadOrCreateUser(event.params.caller);

  const e = new LpFeesHarvestedToRewardsEvent(id);
  e.caller = caller.id;
  e.feeWeth = event.params.feeWeth;
  e.feeClaim = event.params.feeClaim;
  e.claimToRewards = event.params.claimToRewards;
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
