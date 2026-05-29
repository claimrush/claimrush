export const ERC20_ABI = [
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: 'balance', type: 'uint256' }],
  },
] as const;

export const MAINTENANCE_HUB_ABI = [
  {
    type: 'function',
    name: 'poke',
    stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'args',
        type: 'tuple',
        components: [
          { name: 'offerIds', type: 'uint256[]' },
          { name: 'maxOffers', type: 'uint256' },
        ],
      },
    ],
    outputs: [],
  },
] as const;

export const LP_STAKING_VAULT_ABI = [
  {
    type: 'function',
    name: 'harvestFeesToRewards',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'deadline', type: 'uint256' },
      { name: 'minClaimOut', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'lpToken',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'weth',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'claim',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'aerodromeRouter',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'aerodromeFactory',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'wethClaimStable',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 'lastFeeHarvestTs',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },

  // Auto-compound (LP rewards -> Furnace)
  {
    type: 'function',
    name: 'earned',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [{ name: 'amount', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getAutoCompoundConfig',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [
      { name: 'enabled', type: 'bool' },
      { name: 'paused', type: 'bool' },
      { name: 'tokenId', type: 'uint256' },
      { name: 'durationSeconds', type: 'uint256' },
      { name: 'maxSlippageBps', type: 'uint32' },
      { name: 'minRewardToCompound', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'compoundFor',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'compoundForMany',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'users', type: 'address[]' },
      { name: 'maxUsers', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'event',
    name: 'LpRewardsLocked',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'amountClaim', type: 'uint256', indexed: false },
      { name: 'principalClaim', type: 'uint256', indexed: false },
      { name: 'bonusClaim', type: 'uint256', indexed: false },
      { name: 'tokenId', type: 'uint256', indexed: false },
    ],
    anonymous: false,
  },
] as const;

export const AERODROME_POOL_ABI = [
  {
    type: 'function',
    name: 'token0',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'token1',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'claimFees',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [{ type: 'uint256' }, { type: 'uint256' }],
  },
] as const;

export const AERODROME_ROUTER_ABI = [
  {
    type: 'function',
    name: 'getAmountsOut',
    stateMutability: 'view',
    inputs: [
      { name: 'amountIn', type: 'uint256' },
      {
        name: 'routes',
        type: 'tuple[]',
        components: [
          { name: 'from', type: 'address' },
          { name: 'to', type: 'address' },
          { name: 'stable', type: 'bool' },
          { name: 'factory', type: 'address' },
        ],
      },
    ],
    outputs: [{ name: 'amounts', type: 'uint256[]' }],
  },
] as const;

// =============================================================================
// MARKET_ROUTER_ABI - STRICT MODE (v1.0.0+)
// =============================================================================
//
// In Strict Mode:
// - Furnace is the ONLY buyer/sink for veNFT locks.
// - buyLock() does NOT exist (removed).
// - LockBought event does NOT exist (removed).
// - Listing semantics use minClaimOut (not priceInClaim).
// - Only sell paths:
//   - sellLockToFurnace(tokenId, minClaimOut, deadline) - owner sells unlisted/listed lock (deadline enforces anti-stale)
//   - sellListedLockToFurnace(tokenId) - allowlisted settlement-keeper/owner priority for approved listings during grace, then permissionless;
//     stale approval-revoked listings self-clear permissionlessly with claimOut == 0 (reverts after listing expiry)
//   - cancelExpiredListing(tokenId) - permissionless cleanup of expired listings
//
// BonusTargetConfig tuple layout:
//   [0] targetBonusBps (uint256)
//   [1] slippageBps (uint256)
//   [2] configured (bool)
//
// BonusTargetEscrow (offers) tuple layout:
//   [0] buyer (address)
//   [1] discountBps (uint256)
//   [2] durationSeconds (uint256)
//   [3] createAutoMax (bool)
//   [4] destinationLockId (uint256)
//   [5] fundsRemaining (uint256)
//   [6] createdAt (uint256)
//   [7] expiresAt (uint256)
//   [8] active (bool)
// =============================================================================
export const MARKET_ROUTER_ABI = [
  {
    type: 'function',
    name: 'tradingPaused',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'bool' }],
  },
  {
    // Allowlisted settlement-keeper/owner priority for offer execution during grace; permissionless after the exact boundary.
    type: 'function',
    name: 'executeAutoFurnace',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'offerId', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'offers',
    stateMutability: 'view',
    inputs: [{ name: 'offerId', type: 'uint256' }],
    outputs: [
      { name: 'buyer', type: 'address' }, // [0]
      { name: 'discountBps', type: 'uint256' }, // [1]
      { name: 'durationSeconds', type: 'uint256' }, // [2]
      { name: 'createAutoMax', type: 'bool' }, // [3]
      { name: 'destinationLockId', type: 'uint256' }, // [4]
      { name: 'fundsRemaining', type: 'uint256' }, // [5]
      { name: 'createdAt', type: 'uint256' }, // [6]
      { name: 'expiresAt', type: 'uint256' }, // [7]
      { name: 'active', type: 'bool' }, // [8]
    ],
  },
  {
    // BonusTargetConfig tuple: (targetBonusBps, slippageBps, configured)
    type: 'function',
    name: 'bonusTargetConfigs',
    stateMutability: 'view',
    inputs: [{ name: 'offerId', type: 'uint256' }],
    outputs: [
      { name: 'targetBonusBps', type: 'uint256' }, // [0]
      { name: 'slippageBps', type: 'uint256' }, // [1]
      { name: 'configured', type: 'bool' }, // [2]
    ],
  },
  {
    // STRICT MODE: Owner sells (unlisted or listed) lock directly to Furnace.
    // Deadline is enforced onchain to prevent stale execution.
    type: 'function',
    name: 'sellLockToFurnace',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'tokenId', type: 'uint256' },
      { name: 'minClaimOut', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'claimOut', type: 'uint256' }],
  },
  {
    // STRICT MODE: allowlisted settlement-keeper/owner priority for approved listings during grace; permissionless after.
    // Approval-revoked stale listings self-clear permissionlessly with claimOut == 0.
    type: 'function',
    name: 'sellListedLockToFurnace',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'tokenId', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'claimOut', type: 'uint256' }],
  },
  {
    // Get listing details for a tokenId.
    // Listing tuple: (seller, minClaimOut, listedAtTime, expiresAtTime, active)
    type: 'function',
    name: 'getListing',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [
      { name: 'seller', type: 'address' }, // [0]
      { name: 'minClaimOut', type: 'uint256' }, // [1]
      { name: 'listedAtTime', type: 'uint256' }, // [2]
      { name: 'expiresAtTime', type: 'uint256' }, // [3]
      { name: 'active', type: 'bool' }, // [4]
    ],
  },
  {
    type: 'function',
    name: 'cancelExpiredListing',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'cancelExpiredListingBatch',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'tokenIds', type: 'uint256[]' }],
    outputs: [],
  },
  {
    // Get the VeClaimNFT contract address.
    type: 'function',
    name: 've',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 'cancelExpiredBonusTargetEscrow',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'uint256' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'cancelExpiredBonusTargetEscrowBatch',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerIds', type: 'uint256[]' }],
    outputs: [],
  },
] as const;

export const FURNACE_ABI = [
  {
    type: 'function',
    name: 'getLpStreamState',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'ratePerSec', type: 'uint256' },
      { name: 'periodFinish', type: 'uint256' },
      { name: 'lastUpdate', type: 'uint256' },
      { name: 'remaining', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'lockingPaused',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: 'paused', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'claimAutoMaxBonus',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [{ name: 'bonusClaim', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'claimAutoMaxBonusBatch',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'tokenIds', type: 'uint256[]' },
      { name: 'maxLocks', type: 'uint256' },
    ],
    outputs: [{ name: 'totalBonus', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'lastAutoMaxBonusClaim',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    // Quote sell lock to furnace from raw lock info (no tokenId lookup).
    // Used for listing eligibility checks.
    type: 'function',
    name: 'quoteSellLockToFurnaceFromInfo',
    stateMutability: 'view',
    inputs: [
      { name: 'lockAmount', type: 'uint256' },
      { name: 'lockEnd', type: 'uint256' },
      { name: 'autoMax', type: 'bool' },
    ],
    outputs: [
      { name: 'claimOut', type: 'uint256' }, // [0]
      { name: 'spreadBps', type: 'uint256' }, // [1]
      { name: 'lpReward', type: 'uint256' }, // [2]
      { name: 'reserveAdd', type: 'uint256' }, // [3]
    ],
  },
  {
    type: 'function',
    name: 'quoteEnterWithEth',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'ethIn', type: 'uint256' },
      { name: 'targetTokenId', type: 'uint256' },
      { name: 'durationSeconds', type: 'uint256' },
      { name: 'createAutoMax', type: 'bool' },
    ],
    outputs: [
      { name: 'principalClaim', type: 'uint256' },
      { name: 'bonusClaim', type: 'uint256' },
      { name: 'veOut', type: 'uint256' },
      { name: 'routeTokenId', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'quoteEnterWithClaim',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'claimIn', type: 'uint256' },
      { name: 'targetTokenId', type: 'uint256' },
      { name: 'durationSeconds', type: 'uint256' },
      { name: 'createAutoMax', type: 'bool' },
    ],
    outputs: [
      { name: 'principalClaim', type: 'uint256' },
      { name: 'bonusClaim', type: 'uint256' },
      { name: 'veOut', type: 'uint256' },
      { name: 'routeTokenId', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'furnaceQuoter',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
] as const;

export const FURNACE_QUOTER_ABI = [
  {
    type: 'function',
    name: 'filterAutoMaxBonusEligible',
    stateMutability: 'view',
    inputs: [{ name: 'tokenIds', type: 'uint256[]' }],
    outputs: [{ name: 'eligible', type: 'bool[]' }],
  },
  {
    type: 'function',
    name: 'quoteAutoMaxBonusBatch',
    stateMutability: 'view',
    inputs: [{ name: 'tokenIds', type: 'uint256[]' }],
    outputs: [
      { name: 'bonuses', type: 'uint256[]' },
      { name: 'totalBonus', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'lastAutoMaxBonusClaimBatch',
    stateMutability: 'view',
    inputs: [{ name: 'tokenIds', type: 'uint256[]' }],
    outputs: [{ name: 'lastClaims', type: 'uint256[]' }],
  },
] as const;

export const SHAREHOLDER_ROYALTIES_ABI = [
  {
    type: 'function',
    name: 'pendingShareholderETH',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  // B-5 (2026-04-17): governance-updatable global dust floor used by
  // _executeAutoCompoundCore; the keeper reads this per run so a
  // `setMinAutoCompoundEth` raises/lowers selection eligibility immediately.
  {
    type: 'function',
    name: 'minAutoCompoundEth',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'ethPerVe',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: 'ethPerVe', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getShareholderState',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [
      { name: 'claimable', type: 'uint256' },
      { name: 'userVe', type: 'uint256' },
      { name: 'paid', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'getAutoCompoundConfig',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [
      { name: 'enabled', type: 'bool' },
      { name: 'paused', type: 'bool' },
      { name: 'tokenId', type: 'uint256' },
      { name: 'durationSeconds', type: 'uint256' },
      { name: 'minCadenceSeconds', type: 'uint32' },
      { name: 'minEthToCompound', type: 'uint256' },
      { name: 'maxSlippageBps', type: 'uint32' },
      { name: 'lastCompoundTs', type: 'uint40' },
    ],
  },
  // minVeOut is computed on-chain from user's maxSlippageBps (no executor-controlled slippage).
  {
    type: 'function',
    name: 'compoundFor',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'compoundForMany',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'users', type: 'address[]' },
      { name: 'maxUsers', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'checkpointUser',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'checkpointUserBatch',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'users', type: 'address[]' },
      { name: 'maxUsers', type: 'uint256' },
    ],
    outputs: [],
  },
] as const;

export const MINE_CORE_ABI = [
  {
    type: 'event',
    name: 'Takeover',
    inputs: [
      { name: 'reignId', type: 'uint256', indexed: true },
      { name: 'previousKing', type: 'address', indexed: true },
      { name: 'newKing', type: 'address', indexed: true },
      { name: 'pricePaid', type: 'uint256', indexed: false },
      { name: 'referencePrice', type: 'uint256', indexed: false },
      { name: 'reignDuration', type: 'uint256', indexed: false },
    ],
  },
] as const;

export const VE_CLAIM_NFT_ABI = [
  {
    type: 'function',
    name: 'globalLastTs',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'ownerOf',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [{ name: 'owner', type: 'address' }],
  },
  {
    type: 'function',
    name: 'getLockInfo',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [
      { name: 'amount', type: 'uint256' },
      { name: 'lockEnd', type: 'uint256' },
      { name: 'autoMax', type: 'bool' },
      { name: 'listed', type: 'bool' },
    ],
  },
] as const;
