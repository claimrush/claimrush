import { Address, BigInt, Bytes } from '@graphprotocol/graph-ts';

import {
  FeesClaimedAndForwarded,
  GenesisLPVault24M,
  LockExtended,
  Locked,
  ResidualLpSwept,
  TokenRescued,
  WithdrawLp,
} from '../generated/GenesisLPVault24M/GenesisLPVault24M';

import {
  ActivityItem,
  GenesisLpFeeClaimEvent,
  GenesisResidualLpSweepEvent,
  GenesisState,
  GenesisWithdrawLpEvent,
} from '../generated/schema';

import { eventId } from '../utils/id';
import { saveActivityItem } from '../utils/activity';
import { isZeroAddressBytes, loadOrCreateProtocol, setBytesIfZero } from '../utils/protocol';
import { loadOrCreateUser } from '../utils/user';

const GENESIS_STATE_ID = '1';

// Sentinel "user" address used when `lpWithdrawRecipient()` reverts (RPC blip,
// non-conforming vault, ABI drift). Attribution to `event.transaction.from`
// would silently misattribute the fee claim to a relayer / Safe submitter EOA;
// instead we route to a deterministic burn-style address that downstream
// dashboards can filter as "unresolved attribution". The flag
// `recipientResolvedByFallback` on `GenesisLpFeeClaimEvent` mirrors this.
const FALLBACK_RECIPIENT_SENTINEL_HEX = '0x000000000000000000000000000000000000dEaD';
const FALLBACK_RECIPIENT_SENTINEL: Address = Address.fromString(FALLBACK_RECIPIENT_SENTINEL_HEX);

function loadOrCreateGenesisState(): GenesisState {
  let g = GenesisState.load(GENESIS_STATE_ID);
  if (g == null) {
    g = new GenesisState(GENESIS_STATE_ID);
    g.genesisFinalized = false;
    g.finalizedAt = null;
    g.finalizedTxHash = null;
    g.genesisLpVaultLockStart = null;
    g.genesisLpVaultUnlockTime = null;
    g.save();
  }
  return g as GenesisState;
}

function touchGenesisVault(addr: Bytes, blockNumber: BigInt): void {
  const protocol = loadOrCreateProtocol(blockNumber);
  const current = protocol.genesisLpVault24m;
  if (current === null) {
    protocol.genesisLpVault24m = addr;
  } else {
    protocol.genesisLpVault24m = setBytesIfZero(current as Bytes, addr);
  }
  protocol.save();
}

export function handleLocked(event: Locked): void {
  touchGenesisVault(event.address, event.block.number);

  const g = loadOrCreateGenesisState();
  // Only lockStartTime and unlockTime are persisted; the amount is discarded.
  // Consider adding a `genesisLpAmount` field to GenesisState for completeness.
  g.genesisLpVaultLockStart = event.params.lockStartTime;
  g.genesisLpVaultUnlockTime = event.params.unlockTime;
  g.save();
}

export function handleLockExtended(event: LockExtended): void {
  touchGenesisVault(event.address, event.block.number);

  const g = loadOrCreateGenesisState();
  g.genesisLpVaultUnlockTime = event.params.newUnlockTime;
  g.save();
}

export function handleWithdrawLp(event: WithdrawLp): void {
  touchGenesisVault(event.address, event.block.number);

  const id = eventId(event);
  const to = loadOrCreateUser(event.params.to);

  const e = new GenesisWithdrawLpEvent(id);
  e.to = to.id;
  e.amountWei = event.params.amount;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleResidualLpSwept(event: ResidualLpSwept): void {
  touchGenesisVault(event.address, event.block.number);

  const id = eventId(event);
  const to = loadOrCreateUser(event.params.to);

  const e = new GenesisResidualLpSweepEvent(id);
  e.to = to.id;
  e.amountWei = event.params.amount;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function handleFeesClaimedAndForwarded(event: FeesClaimedAndForwarded): void {
  touchGenesisVault(event.address, event.block.number);

  // Recipient is always the immutable `lpWithdrawRecipient`. Source it from a
  // contract call so that Safe-multisig / batched / sponsored withdrawals
  // (where `event.transaction.from` is the EOA submitter, not the recipient)
  // are still attributed to the canonical Safe address. The view call cannot
  // revert in practice (the variable is `immutable`), but `try_*` is used to
  // satisfy AssemblyScript's strict null safety and to defend against transient
  // RPC failures or a non-conforming vault. On revert we route attribution to a
  // FALLBACK_RECIPIENT_SENTINEL (0x...dEaD) instead of `event.transaction.from`
  // because using `tx.from` would silently misattribute fee claims to relayer /
  // Safe-submitter EOAs that did not receive the funds. The
  // `recipientResolvedByFallback` boolean flags the row for downstream filtering.
  const vault = GenesisLPVault24M.bind(event.address);
  const recipientResult = vault.try_lpWithdrawRecipient();
  const recipientResolvedByFallback = recipientResult.reverted;
  const recipient: Address = recipientResolvedByFallback
    ? FALLBACK_RECIPIENT_SENTINEL
    : recipientResult.value;
  const to = loadOrCreateUser(recipient);

  const id = eventId(event);
  const e = new GenesisLpFeeClaimEvent(id);
  e.to = to.id;
  e.recipientResolvedByFallback = recipientResolvedByFallback;
  e.token0 = event.params.token0;
  e.token1 = event.params.token1;
  e.amount0Wei = event.params.amount0Forwarded;
  e.amount1Wei = event.params.amount1Forwarded;
  e.blockNumber = event.block.number;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();

  const a = new ActivityItem(id);
  a.kind = 'GENESIS_VAULT_FEES_CLAIMED_AND_FORWARDED';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = to.id;
  // Resolve which side is CLAIM vs WETH using the protocol's pinned claimToken.
  // The pool's `token0 < token1` ordering is address-defined and not
  // semantically WETH-or-CLAIM-aligned, so we MUST disambiguate by address
  // match. If the claimToken is not yet known to the subgraph (extremely
  // unlikely once a 24-month lock has elapsed, but defensible early state),
  // leave both legs null — consumers should fall back to the underlying
  // GenesisLpFeeClaimEvent's indexed `token0` / `token1` fields.
  const protocol = loadOrCreateProtocol(event.block.number);
  const claimAddr = protocol.claimToken;
  if (claimAddr.toHexString() == event.params.token0.toHexString()) {
    a.amountClaimWei = event.params.amount0Forwarded;
    a.amountEthWei = event.params.amount1Forwarded;
  } else if (claimAddr.toHexString() == event.params.token1.toHexString()) {
    a.amountClaimWei = event.params.amount1Forwarded;
    a.amountEthWei = event.params.amount0Forwarded;
  } else {
    a.amountClaimWei = null;
    a.amountEthWei = null;
  }
  saveActivityItem(a);
}

export function handleTokenRescued(event: TokenRescued): void {
  touchGenesisVault(event.address, event.block.number);

  const id = eventId(event);
  const to = loadOrCreateUser(event.params.to);

  // Discriminate ETH rescues (token == address(0)) from ERC-20 rescues so downstream
  // dashboards can filter without re-decoding the raw token field. v1.0.0 only emits
  // ETH rescues (no rescueERC20 path exists yet); the discriminator is forward-compatible.
  const a = new ActivityItem(id);
  if (isZeroAddressBytes(event.params.token)) {
    a.kind = 'GENESIS_VAULT_ETH_RESCUED';
  } else {
    a.kind = 'GENESIS_VAULT_TOKEN_RESCUED';
  }
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = to.id;
  saveActivityItem(a);
}
