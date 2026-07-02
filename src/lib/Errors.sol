// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Centralized custom errors (gas-efficient).
library Errors {
    // Access control
    error NotAuthorized();

    // Internal invariants (should never happen in correct flows)
    error InvariantViolation();
    error OnlyGuardian();
    error OnlyMineCore();
    error OnlyMineMarket();

    // VeClaimNFT transfer restrictions
    error MarketMustTransferToFurnace();
    error TransfersRestricted();
    error OnlyShareholderRoyalties();
    error OnlyClaimAllHelper();

    // Pause flags
    error TakeoversPaused();
    error TradingPaused();
    error LockingPaused();

    // State validation
    error ZeroAddress();
    error ShareholderRoyaltiesNotSet();
    error ConfigFrozen();
    error MetadataFrozen();
    error InvalidDuration();
    error LockExpired();
    error LockListedOrFrozen();
    // King-stream CLAIM is always locked: the veCLAIM lock route is temporarily unavailable
    // (Furnace locking paused, or a first lock below MIN_LOCK_AMOUNT). The credit is preserved.
    error LockRouteUnavailable();
    error AutoMaxMismatch();
    error ListingNotActive();
    error ListingCooldown();
    error InvalidListingExpiry();
    error ListingExpired();
    error ListingNotExpired();
    error EmergencyDelistTooSoon();
    error OfferNotActive();
    error OfferExpired();
    error OfferNotExpired();

    // Numeric validation
    error InsufficientEthBalance();

    // Enum / mode validation
    error InvalidMode();

    // Shareholder auto-compound
    error AutoCompoundNotEnabled();
    error AutoCompoundPaused();
    error CadenceNotMet();
    error CompoundQuoteFailed();
    error QuoteCallFailed();

    error AmountZero();
    error AmountTooLarge();
    error BatchTooLarge();

    // VeClaimNFT
    error TooManyVeNFTs();
    error VeCheckpointStale();
    error URITooLong();

    // EntryTokenRegistry
    error RouterConfigNotSet();
    error WethClaimHopNotSet();
    error WethClaimHopAlreadySet();
    error TokenNotEnabled();
    error TokenNotConfigured();
    error UnsafeEntryToken();
    error InvalidToken();
    error InvalidPool();
    error FactoryMismatch();
    error WrappedNativeMismatch();
    error WrappedNativeImmutable();
    error ClaimTokenImmutable();

    // LpStakingVault7D
    error InsufficientStake();
    error TooManyUnbonds();
    error NotRewardNotifier();
    error RewardIndexOverflow();

    // Furnace / LP wiring
    error LpRewardsVaultFurnaceMismatch();
    error LpRewardsStreamActive();
    error EmergencyRewireNotRequested();
    error EmergencyRewireDelayNotMet();
    error EmergencyRewireAlreadyRequested();

    // Slippage
    error PriceExceeded();
    error MinVeOutNotMet();
    error MinVeOutRequired();
    error MinEthOutNotMet();
    error MinAmountOutNotMet();

    // Freeze-time cross-contract wiring hardening
    error WiringMismatch();

    // Wiring hardening: reject EIP-7702-delegated EOAs as candidate wiring roots.
    error DelegatedEOA();

    // DEX adapter
    error DeadlineExpired();
    error InvalidRoute();
    error NotAContract();
    error ApprovalFailed();
    error TransferFailed();

    // Return-data bombs (defense-in-depth)
    error ReturnDataTooLarge();

    error InsufficientTokenBalance();
    error InsufficientTokenAllowance();

    // Settlement keeper priority (MEV protection)
    error SettlementKeeperGracePeriod();

    // Offers
    error DiscountTooHigh();
    error SlippageTooHigh();
    error BonusTargetNotConfigured();
    error BonusTargetNotMet();
    error BudgetTooSmall();
    error InvalidOfferTtl();
    error InvalidOfferExpiry();
    error MinLockAmountNotMet();
    error DecreaseNotAllowed();
    error OfferInsufficientFunds();

    // Payments
    error EthTransferFailed();
    error EthValueMismatch();

    // Genesis
    error GenesisWindowNotEnded();
    error GenesisKingClaimNotCollected();
    error GenesisKingClaimAlreadyCollected();
    error GenesisGuardianLocked();
    error GenesisAlreadyFinalized();
    error GenesisExactSeedRequired();
    error GenesisAccrualWindowNotComplete();
    error GenesisMustBePaused();
    error GenesisPoolMismatch();
    error GenesisWethMismatch();
    error GenesisNoClaimForLiquidity();
    error GenesisLpMintFailed();
    error GenesisLpBalanceMismatch();

    // Escrow budget governance
    error BudgetTooHigh();

    // Unbond validation
    error AmountTooSmall();

    // ShareholderRoyalties wiring safety
    error PendingEthNotDrained();

    // VeClaimNFT checkpoint freshness
    error CheckpointStale();
}
