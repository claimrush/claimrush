# Errors Reference

> v1.0.0 — canonical source: `src/lib/Errors.sol` plus per-contract locals.

This page maps every revert an integrator can observe back to the contract that emits it, the condition that triggers it, and the recovery path. Errors that ship via standard OpenZeppelin paths (`OwnableUnauthorizedAccount`, `OwnableInvalidOwner`, `InvalidInitialization`, `ReentrancyGuardReentrantCall`) are inherited and not re-documented here — selectors match the upstream library.

## How errors are organized

- **`src/lib/Errors.sol`** is the central library shared across the runtime contracts. Most reverts an integrator observes resolve to this library.
- **Per-contract locals** live next to the contract that declares them. They cover surface-specific concerns (LP vault staking, genesis sequencing, agent-lens self-call gating).
- **Selector-encoded payloads** — a few errors carry an address argument (`DelegatedEOAOwner(address)`, `OwnableUnauthorizedAccount(address)`). The 4-byte selector plus the encoded address is the full revert payload.

## Access control

| Error | Reverts from | Trigger |
|---|---|---|
| `NotAuthorized` | Most contracts | Caller is not the role expected by the surface (e.g. non-keeper hitting a keeper-only path; non-King calling `setCurrentReignRecipients` without a delegated permission bit). |
| `OnlyGuardian` | Pause-bearing contracts | Pause / unpause attempted by a non-guardian caller. |
| `OnlyMineCore` | `Furnace`, `ShareholderRoyalties`, `VeClaimNFT` | Cross-contract callback expected from the canonical `MineCore` arrived from another caller. |
| `OnlyMineMarket` | `VeClaimNFT` | veNFT transfer hook invoked from a non-canonical market path. |
| `OnlyShareholderRoyalties` | `VeClaimNFT` | Royalty-side checkpoint hook invoked from a non-canonical royalty surface. |
| `OnlyClaimAllHelper` | `MineCore`, `ShareholderRoyalties` | Helper-bundle entrypoint invoked from outside the canonical `ClaimAllHelper`. |

## Pause flags

| Error | Reverts from | Trigger |
|---|---|---|
| `TakeoversPaused` | `MineCore` | Guardian has set `takeoversPaused = true`. Mining clamps; refunds and withdrawals stay available. See [Security, Guardian, Pausing](security-guardian-pausing.md). |
| `LockingPaused` | `Furnace` | Guardian has set `lockingPaused = true`. Lock-creation and royalty `mode=1` paths revert; `mode=0` Collect still works. |
| `TradingPaused` | `MarketRouter` | Guardian has set `tradingPaused = true`. New listings and escrow execution revert; safety unwind paths (delist, cancel-expired) remain available. |

## Wiring and EIP-7702 guards

| Error | Reverts from | Trigger |
|---|---|---|
| `WiringMismatch` | Every state-changing canonical-bundle call | The runtime cross-check found a stored pointer that no longer agrees with the canonical bundle. Re-verify wiring on the Security page; clients should fail closed. |
| `DelegatedEOA` | Wiring setters and `Ownable2Step` ownership transfers | Candidate address is an EIP-7702 delegated EOA (23-byte runtime starting `0xEF 0x01 0x00`). |
| `DelegatedEOAOwner(address)` | `UpgradeableProtocolBase`-rooted contracts (`MineCore`, `MarketRouter`, `ShareholderRoyalties`) | Same condition as above, surfaced on `transferOwnership(newOwner)` for the proxy-backed runtime. |
| `NotAContract` | Wiring setters; also covers 7702 case on `MineCore` and `MaintenanceHub` | Candidate address has `code.length == 0`. |
| `ZeroAddress` | Wiring setters and many surface calls | `address(0)` passed where a live contract is required. |
| `ConfigFrozen` | All freeze-gated contracts | Wiring setter called after the freeze ceremony executed for that contract. |
| `MetadataFrozen` | `VeClaimNFT` | ERC-721 metadata setter called after the metadata freeze. |
| `ShareholderRoyaltiesNotSet` | `Furnace` | Royalty surface not yet wired into the Furnace. Pre-launch only. |
| `PendingEthNotDrained` | `ShareholderRoyalties` | Wiring rotation attempted while `pendingShareholderETH > 0`. Flush first via `flushPendingShareholderETH()`. |

## Slippage and quote freshness

| Error | Reverts from | Trigger |
|---|---|---|
| `PriceExceeded` | `MineCore` | Current takeover price exceeds `maxPrice`. |
| `MinVeOutNotMet` | `Furnace`, `ShareholderRoyalties`, `LpStakingVault7D` | Resulting veCLAIM under the caller's `minVeOut`. |
| `MinVeOutRequired` | `Furnace` (compound paths) | Caller passed `minVeOut == 0` on a path that mandates an explicit floor. |
| `MinEthOutNotMet` | `MineCore` (`takeoverWithToken`) | Token → ETH swap settled below `minEthOut`. |
| `MinAmountOutNotMet` | `DexAdapter` | Generic AMM swap settled below the caller-supplied floor. |
| `MinClaimOutRequired` | `LpStakingVault7D` | Auto-compound path requires an explicit `minClaimOut`. |
| `MinClaimFloorNotMet` | `LpStakingVault7D` | Quoted CLAIM below the protocol floor. |
| `DeadlineExpired` | `DexAdapter`, swap-wrapping entrypoints | Block timestamp past the swap deadline. |
| `CheckpointStale` / `VeCheckpointStale` | `ShareholderRoyalties`, `VeClaimNFT` | Royalty flush requires a current ve checkpoint and the bounded checkpoint did not catch up in the same block. Call `MineCore.advanceVeCheckpoint()` or wait for the next maintenance poke. |

## Locks (veCLAIM)

| Error | Reverts from | Trigger |
|---|---|---|
| `InvalidDuration` | `Furnace`, `VeClaimNFT` | Requested duration outside the `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]` window. |
| `LockExpired` | Lock surfaces and `MarketRouter` | Action targets a lock with `endTimestamp <= now` outside the wait-for-expiry path. |
| `LockListedOrFrozen` | `Furnace`, `VeClaimNFT` | Action targets a lock that is currently listed on the Market or frozen by the keeper grace window. |
| `AutoMaxMismatch` | `Furnace` | Merge attempted between two locks with incompatible AutoMax flags outside the supported mixed-pair rule. |
| `TooManyVeNFTs` | `VeClaimNFT` | Owner already holds `MAX_LOCKS_PER_USER` (32) lock NFTs. |
| `TransfersRestricted` | `VeClaimNFT` | ERC-721 transfer attempted outside the allow-listed `Furnace ↔ MarketRouter` paths. |
| `MarketMustTransferToFurnace` | `VeClaimNFT` | Market-routed transfer destination is not the Furnace. |

## Market (MarketRouter)

| Error | Reverts from | Trigger |
|---|---|---|
| `ListingNotActive` | `MarketRouter` | Listing already filled, cancelled, or expired. |
| `ListingCooldown` | `MarketRouter` | Relist attempt inside the post-fill cooldown window. |
| `InvalidListingExpiry` | `MarketRouter` | Listing expiry outside the allowed bounds. |
| `ListingExpired` | `MarketRouter` | Settlement attempted on an expired listing outside emergency-delist semantics. |
| `ListingNotExpired` | `MarketRouter` | Emergency delist attempted before `EMERGENCY_DELIST_DELAY`. |
| `EmergencyDelistTooSoon` | `MarketRouter` | Owner break-glass delist invoked inside the settlement keeper grace window. |
| `OfferNotActive` | `MarketRouter` | Offer already filled or cancelled. |
| `OfferExpired` | `MarketRouter` | Offer past its TTL. |
| `OfferNotExpired` | `MarketRouter` | Cancel attempted before TTL elapsed (when only the owner can cancel). |
| `BonusTargetNotConfigured` | `MarketRouter` | Offer references a bonus-target gate that was never set. |
| `BonusTargetNotMet` | `MarketRouter` | Furnace bonus below the offer's `bonusBpsVsPrincipalClaim` target. |
| `BudgetTooSmall` / `BudgetTooHigh` | `MarketRouter` | Escrow budget outside the configured min/max envelope. |
| `InvalidOfferTtl` / `InvalidOfferExpiry` | `MarketRouter` | TTL or expiry violates the allowed ranges. |
| `MinLockAmountNotMet` | `MarketRouter` | Offer settled below the offerer's minimum lock principal. |
| `DecreaseNotAllowed` | `MarketRouter` | Offer modification attempted to decrease a parameter that is set-once. |
| `OfferInsufficientFunds` | `MarketRouter` | Offerer escrow balance insufficient for the requested execution. |
| `DiscountTooHigh` / `SlippageTooHigh` | `MarketRouter` | Sell-now spread exceeded the caller-supplied limit. |
| `SettlementKeeperGracePeriod` | `MarketRouter` | Public settlement attempted inside the keeper grace window. |

## Furnace bonus and LP stream

| Error | Reverts from | Trigger |
|---|---|---|
| `AmountZero` | `Furnace`, `LpStakingVault7D`, `MarketRouter` | Caller passed `amountIn == 0`. |
| `AmountTooLarge` / `AmountTooSmall` | Multiple | Amount outside the surface-specific envelope. |
| `BatchTooLarge` | Batch surfaces | Batch length exceeded the per-call cap. |
| `InvalidMode` | `ShareholderRoyalties` | `claimShareholder(mode, ...)` called with a `mode` outside `{0, 1}`. |
| `LpRewardsVaultFurnaceMismatch` | `Furnace` | Candidate LP rewards vault does not back-point to the calling Furnace. |
| `LpRewardsStreamActive` | `Furnace` | Wiring rotation attempted while the LP stream still has unclaimed accrual. |
| `EmergencyRewireNotRequested` / `EmergencyRewireDelayNotMet` / `EmergencyRewireAlreadyRequested` | `Furnace` | Emergency LP-vault rewire state-machine violation. |

## Auto-compound (Barons / LP)

| Error | Reverts from | Trigger |
|---|---|---|
| `AutoCompoundNotEnabled` | `ShareholderRoyalties`, `LpStakingVault7D` | Keeper invoked compound for a user that has not opted in. |
| `AutoCompoundPaused` | `ShareholderRoyalties` | User-level compound paused after a `ShareholderAutoCompoundFailed`. Re-enable via the explicit unpause surface. |
| `CadenceNotMet` | Keeper paths | Compound invoked inside the per-user cadence window. |
| `CompoundQuoteFailed` | `ShareholderRoyalties` | Off-chain quote handed to the auto-compound path failed validation. |
| `QuoteCallFailed` | `ShareholderRoyalties`, `LpStakingVault7D` | Onchain quote call to the Furnace / LP quoter reverted. Batch path skips the user instead of pausing. |
| `HarvestQuoteFailed` | `LpStakingVault7D` | Onchain quote failed during keeper harvest. |
| `CallerQuoteDivergence` | `LpStakingVault7D` | Caller-supplied quote diverged from the onchain re-quote outside tolerance. |

## EntryTokenRegistry and DexAdapter

| Error | Reverts from | Trigger |
|---|---|---|
| `RouterConfigNotSet` / `WethClaimHopNotSet` / `WethClaimHopAlreadySet` | `EntryTokenRegistry` | Wiring sequencing violation. |
| `TokenNotEnabled` | `EntryTokenRegistry` | Caller attempted a swap path through a token the guardian has disabled. |
| `TokenNotConfigured` | `EntryTokenRegistry` | Token has no registered route. |
| `UnsafeEntryToken` | `EntryTokenRegistry` | Token rejected by the entry-token safety filter. |
| `InvalidToken` / `InvalidPool` / `InvalidRoute` | `EntryTokenRegistry`, `DexAdapter` | Route validation failed at admin or runtime. |
| `FactoryMismatch` / `WrappedNativeMismatch` / `WrappedNativeImmutable` / `ClaimTokenImmutable` | `EntryTokenRegistry` | Immutable wiring constants disagree with the supplied candidate. |
| `ApprovalFailed` / `TransferFailed` | `DexAdapter`, `SafeApprove` | ERC-20 approval or transfer call failed or returned `false`. |
| `ReturnDataTooLarge` | `DexAdapter`, low-level wrappers | Token implementation returned more bytes than the defensive cap. |
| `InsufficientTokenBalance` / `InsufficientTokenAllowance` | Multiple | Standard ERC-20 preconditions. |

## LP Staking Vault (LpStakingVault7D)

| Error | Reverts from | Trigger |
|---|---|---|
| `InsufficientStake` | `LpStakingVault7D` | Unbond / withdraw amount exceeds staked balance. |
| `TooManyUnbonds` | `LpStakingVault7D` | User already holds the per-wallet unbond cap. |
| `NotRewardNotifier` | `LpStakingVault7D` | `notifyRewards` invoked from outside the allowlist. |
| `RewardIndexOverflow` | `LpStakingVault7D` | Reward index arithmetic would overflow. |
| `NoFeesToHarvest` | `LpStakingVault7D` | LP fee harvest invoked with no accrued fees. |
| `DeadlineTooFar` | `LpStakingVault7D` | Auto-compound deadline beyond the per-surface cap. |
| `LockCooldown` | `LpStakingVault7D` | Auto-compound destination lock inside its post-action cooldown. |

## Payments and ETH transport

| Error | Reverts from | Trigger |
|---|---|---|
| `EthTransferFailed` | Multiple | Best-effort ETH send reverted; pull-payment balance was credited on caller-side surfaces. |
| `EthValueMismatch` | Multiple | `msg.value` does not match the surface-specific expectation. |
| `InsufficientEthBalance` | Multiple | Internal pull-payment bucket underflow. |

## Genesis

| Error | Reverts from | Trigger |
|---|---|---|
| `GenesisWindowNotEnded` / `GenesisAccrualWindowNotComplete` | `LaunchController`, `MineCore` | Finalization attempted before `GENESIS_ACCRUAL_DURATION` elapsed. |
| `GenesisKingClaimNotCollected` / `GenesisKingClaimAlreadyCollected` | `LaunchController` | Sequencing violation around the one-shot `collectGenesisKingClaim` step. |
| `GenesisGuardianLocked` | `MineCore` | Guardian rotation attempted during the genesis exception window. |
| `GenesisAlreadyFinalized` | `LaunchController` | Second `finalizeGenesis()` call. |
| `GenesisExactSeedRequired` | `LaunchController` | Supplied seed ETH did not equal `requiredSeedEth`. |
| `GenesisMustBePaused` | `MineCore` | Genesis sequencing requires `takeoversPaused == true` at the moment of finalization. |
| `GenesisPoolMismatch` / `GenesisWethMismatch` | `LaunchController` | Pool / WETH pin disagrees with the live deployment. |
| `GenesisNoClaimForLiquidity` | `LaunchController` | Collected King CLAIM bucket was empty when seeding. |
| `GenesisLpMintFailed` / `GenesisLpBalanceMismatch` | `LaunchController` | LP seed arithmetic disagreed with the realized mint. |
| `PoolNotEmpty` / `PoolDonationRemains` | `LaunchController` | Pool received donations before genesis seeding. |

## Genesis LP Vault (GenesisLPVault24M)

| Error | Reverts from | Trigger |
|---|---|---|
| `LockAlreadyStarted` / `LockNotStarted` | `GenesisLPVault24M` | 24-month lock sequencing violation. |
| `NoLp` | `GenesisLPVault24M` | Lock surface invoked with no LP. |
| `OnlyLpWithdrawRecipient` | `GenesisLPVault24M` | Withdrawal attempted from a non-recipient. |
| `UnlockTimeNotReached` / `UnlockTimeNotIncreased` | `GenesisLPVault24M` | Lock extension or withdrawal timing violation. |
| `ExtensionTooLong` / `ExtensionTooShort` | `GenesisLPVault24M` | Requested extension outside the configured bounds. |
| `AlreadyWithdrawn` | `GenesisLPVault24M` | Second withdrawal attempt against the same epoch. |
| `DustLock` | `GenesisLPVault24M` | Lock principal below the dust floor. |
| `NoTokenToRescue` | `GenesisLPVault24M` | Owner rescue called against an empty bucket. |

## Internal invariants

These should never reach an integrator. If you observe one, file a bug.

| Error | Notes |
|---|---|
| `InvariantViolation` | Defensive cross-check failed inside the runtime. |
| `URITooLong` | Metadata override exceeded the bounded cap. |
| `SelfCallOnly` (`AgentLens`) | Reentrant lens call from outside the lens. |

## See also

- [Events and Indexing](events-and-indexing.md) — companion event reference
- [Security, Guardian, Pausing](security-guardian-pausing.md) — pause semantics and 7702 guards
- [Glossary](glossary.md) — terms used in error descriptions
- Source: `src/lib/Errors.sol`
