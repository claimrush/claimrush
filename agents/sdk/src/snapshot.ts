import type { Abi, Address, PublicClient } from 'viem';
import type { AbiNetwork } from './abis.js';
import { loadAbi } from './abis.js';
import type { DeploymentManifest } from './manifest.js';
import { parseStrictSafeInteger, parseStrictNonNegativeSafeInteger } from './integers.js';
import { safeErrorString } from './security/redact.js';

/**
 * Fail-closed parser for snapshot-shaped numeric inputs.
 *
 * Accepts only canonical safe integers (number, bigint within safe range, or
 * a strict decimal string). Fractional, exponential, or suffixed values
 * return the fallback so callers surface misconfigured env vars / persisted
 * state instead of silently truncating.
 */
export function parseSnapshotSafeNumber(value: unknown, fallback?: number): number | undefined {
  const n = parseStrictSafeInteger(value);
  return n === undefined ? fallback : n;
}

/**
 * Fail-closed parser for snapshot-shaped non-negative numeric inputs.
 *
 * Negative, fractional, exponential, or suffixed values return the fallback.
 */
export function parseSnapshotNonNegativeSafeNumber(
  value: unknown,
  fallback?: number,
): number | undefined {
  const n = parseStrictNonNegativeSafeInteger(value);
  return n === undefined ? fallback : n;
}

export type SnapshotOptions = {
  publicClient: PublicClient;
  manifest: DeploymentManifest;
  /** Which ABI folder to read from. Default: base_sepolia. */
  abiNetwork?: AbiNetwork;
  /** Optional explicit repo root. */
  repoRoot?: string;
  /** Optional multicall3 address override (useful on local devnets). */
  multicallAddress?: Address;

  /** Prefer using onchain AgentLens if deployed (reduces RPC calls). Default: true. */
  preferOnchainLens?: boolean;

  /** Optional AgentLens address override (if not present in manifest). */
  agentLensAddress?: Address;

  /** If provided, include a user/account slice. */
  user?: Address;

  /** Include user market listings & offers details (may add many calls). Default: true. */
  includeUserMarketDetails?: boolean;

  /** Hard cap for user listings/offers detail expansion. Default: 100 each. */
  maxUserMarketItems?: number;
};

export type FurnaceStateSnapshot = {
  reserve: bigint;
  lockedSupply: bigint;
  userSpotBonusBps: bigint;
  lpTopupRateBps: bigint;
  quoteUserBonusBps: bigint;
  quoteLpTopupBps: bigint;
  virtualDepth: bigint;
  lastUpdate: bigint;
};

export type MineCoreReignInfoSnapshot = {
  king: Address;
  startTime: bigint;
  endTime: bigint;
  pricePaid: bigint;
  referencePrice: bigint;
  totalClaimMined: bigint;
  totalEthToKing: bigint;
};

export type MarketListingSnapshot = {
  seller: Address;
  minClaimOut: bigint;
  listedAtTime: bigint;
  expiresAtTime: bigint;
  active: boolean;
};

export type BonusTargetEscrowSnapshot = {
  buyer: Address;
  discountBps: bigint;
  durationSeconds: bigint;
  createAutoMax: boolean;
  destinationLockId: bigint;
  fundsRemaining: bigint;
  createdAt: bigint;
  expiresAt: bigint;
  active: boolean;
};

export type BonusTargetConfigSnapshot = {
  targetBonusBps: bigint;
  slippageBps: bigint;
  configured: boolean;
};

export type LockInfoSnapshot = {
  amount: bigint;
  lockEnd: bigint;
  autoMax: boolean;
  listed: boolean;
};

export type UserMarketListingSnapshot = {
  tokenId: bigint;
  listing: MarketListingSnapshot;
  lastListingActionBlock: bigint;
  lockInfo: LockInfoSnapshot;
};

export type UserBonusTargetEscrowSnapshot = {
  offerId: bigint;
  escrow: BonusTargetEscrowSnapshot;
  config: BonusTargetConfigSnapshot;
  expiryBounds: {
    createdAt: bigint;
    expiresAt: bigint;
    maxExpiresAt: bigint;
  };
};

export type ClaimRushSnapshot = {
  meta: {
    snapshotVersion: 'v1';
    manifestVersion: string;
    chain: string;
    chainId: number;
    blockNumber: bigint;
    blockTimestamp: bigint;
  };
  addresses: Record<string, Address>;

  claim: {
    address: Address;
    name: string;
    symbol: string;
    decimals: number;
    totalSupply: bigint;
  };

  mineCore: {
    address: Address;
    currentKing: Address;
    currentReignId: bigint;
    currentReignStartTime: bigint;
    currentReignLastAccrualTime: bigint;
    takeoversPaused: boolean;

    currentTakeoverPrice: bigint;
    referencePrice: bigint;

    emissionStartTime: bigint;
    currentFurnaceEmissionRate: bigint;
    /**
     * King emission rate (CLAIM wei/sec) at snapshot time. Read directly from
     * `AgentLens.currentKingEmissionRate` when available; otherwise derived as
     * `currentFurnaceEmissionRate * 10n` from the 10:1 launch+floor split pinned
     * in `Constants.sol` (see `testKingFurnaceLaunchRateRatioPinned` and
     * `testKingFurnaceFloorRatioPinnedWithin5Wei` in
     * `test/SecurityCriticalConstantsPinned.t.sol`). Drift bound: ~5-15 wei.
     *
     * Agent strategies should size reign budgets against this value, not against
     * `currentFurnaceEmissionRate` (the Furnace stream is 1/10 of the King
     * stream, so naively using the Furnace rate underestimates the King emission
     * rate by 10× and triggers spurious `cap_delay` waits).
     */
    currentKingEmissionRate: bigint;

    genesisAccrualDuration: bigint;
    genesisKingClaimMinted: bigint;
    genesisKingClaimCollected: boolean;

    configFrozen: boolean;
    guardian: Address;

    furnace: Address;
    ve: Address;
    royalties: Address;
    entryTokenRegistry: Address;
    delegationHub: Address;
    claimAllHelper: Address;

    currentReign?: {
      ethRecipient: Address;
      claimRecipient: Address;
      info: MineCoreReignInfoSnapshot;
    };
  };

  furnace: {
    address: Address;
    state: FurnaceStateSnapshot;

    lockingPaused: boolean;

    furnaceReserve: bigint;
    bonusVirtualDepth: bigint;

    capInflowPerDay: bigint;
    furnaceInflowPerDay: bigint;

    lpOverflowDripPerDay: bigint;
    lpSaleRewardCapPerDay: bigint;
    lpSaleRewardCapRemaining: bigint;
    lpSaleRewardFundedToday: bigint;

    lpStreamState: {
      ratePerSec: bigint;
      periodFinish: bigint;
      lastUpdate: bigint;
      remaining: bigint;
    };

    sellImpactVolume: bigint;
    lastBonusUpdate: bigint;
    lastSellImpactUpdate: bigint;

    configFrozen: boolean;
    deploymentTime: bigint;
    guardian: Address;

    mineCore: Address;
    mineMarket: Address;
    lpRewardsVault: Address;
    entryTokenRegistry: Address;
    delegationHub: Address;
    furnaceQuoter: Address;
  };

  royalties: {
    address: Address;
    ethPerVe: bigint;
    pendingShareholderETH: bigint;
    configFrozen: boolean;

    mineCore: Address;
    mineMarket: Address;
    furnace: Address;
    ve: Address;
    claimAllHelper: Address;
  };

  ve: {
    address: Address;
    name: string;
    symbol: string;
    totalLockedClaim: bigint;
    /** Cached total ve (updated on checkpointTotalVe). Used on-chain as pro-rata denominator. */
    totalVeCached: bigint;
    /**
     * View-only total ve (same formula as cached). Not checkpointed in this call; only as fresh as globalLastTs.
     * Use for UI share-of-total denominator; pair with globalLastTs to interpret freshness.
     */
    totalVeCurrent: bigint;
    /** Timestamp of last global bias/ve update. totalVeCurrent is at most as fresh as this. */
    globalLastTs: bigint;

    claimToken: Address;
    furnace: Address;
    mineMarket: Address;
  };

  market: {
    address: Address;
    tradingPaused: boolean;
    nextOfferId: bigint;

    minBonusTargetEscrowBudget: bigint;
    maxBonusTargetEscrowDiscountBps: bigint;

    guardian: Address;
    configFrozen: boolean;

    claim: Address;
    ve: Address;
    royalties: Address;
  };

  lpVault7D: {
    address: Address;
    lpToken: Address;
    weth: Address;
    ve: Address;
    furnace: Address;

    totalStaked: bigint;
    queuedRewards: bigint;
    rewardPerTokenStored: bigint;
    lastFeeHarvestTs: bigint;
    accountedRewardBalance: bigint;

    totalClaimRewardsClaimed: bigint;
    totalClaimRewardsFundedFromFurnace: bigint;
    totalClaimRewardsFundedFromVaultFees: bigint;
    totalClaimRewardsLockedViaFurnace: bigint;
  };

  registries: {
    furnaceEntryTokenRegistry: {
      address: Address;
      routerConfig: {
        router: Address;
        factory: Address;
        wrappedNative: Address;
        claimToken: Address;
      };
      wethClaimHop: Address;
    };
    takeoverEntryTokenRegistry: {
      address: Address;
      routerConfig: {
        router: Address;
        factory: Address;
        wrappedNative: Address;
        claimToken: Address;
      };
      wethClaimHop: Address;
    };
  };

  dexAdapter: {
    address: Address;
    wrappedNative: Address;
    weth: Address;
    aerodromeRouter: Address;
    aerodromeFactory: Address;
    defaultFactory: Address;
  };

  launch: {
    address: Address;
    genesisFinalized: boolean;
    genesisFinalizedAt: bigint;

    genesisClaimMinted: bigint;
    genesisLpMinted: bigint;

    expectedPool: Address;
    genesisLpVault: Address;

    claim: Address;
    mineCore: Address;
    weth: Address;
    aerodromeRouter: Address;
  };

  genesis: {
    lpVault24M: {
      address: Address;
      pool: Address;
      lpWithdrawRecipient: Address;
      lpLockedAmount: bigint;
      lockStartTime: bigint;
      unlockTime: bigint;
      initialLockDuration: bigint;
    };
  };

  user?: {
    address: Address;
    ethBalance: bigint;
    claimBalance: bigint;

    mineCore: {
      kingEthBalance: bigint;
      refundEthBalance: bigint;
      kingAutoLockConfig: {
        enabled: boolean;
        targetTokenId: bigint;
        pinnedTokenId: bigint;
        durationSeconds: number;
        createAutoMax: boolean;
        minVeOut: bigint;
      };
    };

    royalties: {
      shareholderState: {
        claimable: bigint;
        userVe: bigint;
        paid: bigint;
      };
      autoCompoundConfig: {
        enabled: boolean;
        paused: boolean;
        tokenId: bigint;
        durationSeconds: bigint;
        minCadenceSeconds: number;
        minEthToCompound: bigint;
        lastCompoundTs: number;
      };
    };

    ve: {
      nftBalance: bigint;
      veBalance: bigint;
    };

    market: {
      listings: UserMarketListingSnapshot[];
      listingsTruncated: boolean;
      offers: UserBonusTargetEscrowSnapshot[];
      offersTruncated: boolean;
    };

    lpVault7D: {
      stakedBalance: bigint;
      earned: bigint;
      rewards: bigint;
      unbondCount: bigint;
      autoCompoundConfig: {
        enabled: boolean;
        paused: boolean;
        tokenId: bigint;
        durationSeconds: bigint;
      };
    };
  };

  diagnostics: {
    usedOnchainLensGlobal: boolean;
    usedOnchainLensUser: boolean;
    onchainLensAddress?: Address;

    usedMulticall: boolean;
    failures: Array<{ key: string; error: string }>;
  };
};

type CallSpec = {
  key: string;
  call: {
    address: Address;
    abi: Abi;
    functionName: string;
    args?: readonly unknown[];
  };
};

type MulticallResult =
  | {
      status: 'success';
      result: unknown;
    }
  | {
      status: 'failure';
      error: unknown;
    };

function isAddress(s: string): s is Address {
  return /^0x[a-fA-F0-9]{40}$/.test(s);
}

function asAddress(
  v: unknown,
  fallback: Address = '0x0000000000000000000000000000000000000000',
): Address {
  if (typeof v === 'string' && isAddress(v)) return v;
  return fallback;
}

function asBigInt(v: unknown, fallback: bigint = 0n): bigint {
  if (typeof v === 'bigint') return v;
  if (typeof v === 'number') return BigInt(v);
  if (typeof v === 'string' && /^\d+$/.test(v)) return BigInt(v);
  return fallback;
}

function asBool(v: unknown, fallback = false): boolean {
  if (typeof v === 'boolean') return v;
  return fallback;
}

function asNumber(v: unknown, fallback = 0): number {
  if (typeof v === 'number') return v;
  if (typeof v === 'bigint') return Number(v);
  if (typeof v === 'string' && /^\d+$/.test(v)) return Number(v);
  return fallback;
}

function asTuple(v: unknown): readonly unknown[] {
  if (Array.isArray(v)) return v;
  // viem sometimes returns tuple-like objects with numeric keys
  if (v && typeof v === 'object') {
    const obj: any = v as any;
    const out: unknown[] = [];
    for (let i = 0; ; i++) {
      if (!(i in obj)) break;
      out.push(obj[i]);
    }
    if (out.length > 0) return out;
  }
  return [];
}

function parseFurnaceState(raw: unknown): FurnaceStateSnapshot {
  const t = asTuple(raw);
  return {
    reserve: asBigInt(t[0]),
    lockedSupply: asBigInt(t[1]),
    userSpotBonusBps: asBigInt(t[2]),
    lpTopupRateBps: asBigInt(t[3]),
    quoteUserBonusBps: asBigInt(t[4]),
    quoteLpTopupBps: asBigInt(t[5]),
    virtualDepth: asBigInt(t[6]),
    lastUpdate: asBigInt(t[7]),
  };
}

function parseMineCoreReignInfo(raw: unknown): MineCoreReignInfoSnapshot {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    king: asAddress(obj?.king ?? t[0]),
    startTime: asBigInt(obj?.startTime ?? t[1]),
    endTime: asBigInt(obj?.endTime ?? t[2]),
    pricePaid: asBigInt(obj?.pricePaid ?? t[3]),
    referencePrice: asBigInt(obj?.referencePrice ?? t[4]),
    totalClaimMined: asBigInt(obj?.totalClaimMined ?? t[5]),
    totalEthToKing: asBigInt(obj?.totalEthToKing ?? t[6]),
  };
}

function parseListing(raw: unknown): MarketListingSnapshot {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    seller: asAddress(obj?.seller ?? t[0]),
    minClaimOut: asBigInt(obj?.minClaimOut ?? t[1]),
    listedAtTime: asBigInt(obj?.listedAtTime ?? t[2]),
    expiresAtTime: asBigInt(obj?.expiresAtTime ?? t[3]),
    active: asBool(obj?.active ?? t[4]),
  };
}

function parseBonusTargetEscrow(raw: unknown): BonusTargetEscrowSnapshot {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    buyer: asAddress(obj?.buyer ?? t[0]),
    discountBps: asBigInt(obj?.discountBps ?? t[1]),
    durationSeconds: asBigInt(obj?.durationSeconds ?? t[2]),
    createAutoMax: asBool(obj?.createAutoMax ?? t[3]),
    destinationLockId: asBigInt(obj?.destinationLockId ?? t[4]),
    fundsRemaining: asBigInt(obj?.fundsRemaining ?? t[5]),
    createdAt: asBigInt(obj?.createdAt ?? t[6]),
    expiresAt: asBigInt(obj?.expiresAt ?? t[7]),
    active: asBool(obj?.active ?? t[8]),
  };
}

function parseBonusTargetConfig(raw: unknown): BonusTargetConfigSnapshot {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    targetBonusBps: asBigInt(obj?.targetBonusBps ?? t[0]),
    slippageBps: asBigInt(obj?.slippageBps ?? t[1]),
    configured: asBool(obj?.configured ?? t[2]),
  };
}

function parseLockInfo(raw: unknown): LockInfoSnapshot {
  const t = asTuple(raw);
  return {
    amount: asBigInt(t[0]),
    lockEnd: asBigInt(t[1]),
    autoMax: asBool(t[2]),
    listed: asBool(t[3]),
  };
}

function parseRouterConfig(raw: unknown): {
  router: Address;
  factory: Address;
  wrappedNative: Address;
  claimToken: Address;
} {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    router: asAddress(obj?.router ?? t[0]),
    factory: asAddress(obj?.factory ?? t[1]),
    wrappedNative: asAddress(obj?.wrappedNative ?? t[2]),
    claimToken: asAddress(obj?.claimToken ?? t[3]),
  };
}

function parseLpStreamState(raw: unknown): {
  ratePerSec: bigint;
  periodFinish: bigint;
  lastUpdate: bigint;
  remaining: bigint;
} {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    ratePerSec: asBigInt(obj?.ratePerSec ?? t[0]),
    periodFinish: asBigInt(obj?.periodFinish ?? t[1]),
    lastUpdate: asBigInt(obj?.lastUpdate ?? t[2]),
    remaining: asBigInt(obj?.remaining ?? t[3]),
  };
}

async function safeMulticall(params: {
  publicClient: PublicClient;
  calls: CallSpec[];
  multicallAddress?: Address;
}): Promise<{ usedMulticall: boolean; results: MulticallResult[] }> {
  try {
    const res = (await params.publicClient.multicall({
      contracts: params.calls.map((c) => c.call),
      allowFailure: true,
      multicallAddress: params.multicallAddress,
    })) as MulticallResult[];
    return { usedMulticall: true, results: res };
  } catch {
    // Fallback to sequential read calls if multicall isn't supported (eg local anvil without Multicall3).
    const out: MulticallResult[] = [];
    for (const c of params.calls) {
      try {
        const r = await params.publicClient.readContract({
          address: c.call.address,
          abi: c.call.abi,
          functionName: c.call.functionName as any,
          args: c.call.args as any,
        });
        out.push({ status: 'success', result: r });
      } catch (err: unknown) {
        out.push({ status: 'failure', error: err });
      }
    }
    return { usedMulticall: false, results: out };
  }
}

function _getResult(map: Map<string, MulticallResult>, key: string): MulticallResult | undefined {
  return map.get(key);
}

function unwrap<T = unknown>(res: MulticallResult | undefined, fallback?: T): T {
  if (!res) return (fallback as T) ?? (undefined as T);
  if (res.status === 'success') return res.result as T;
  return (fallback as T) ?? (undefined as T);
}

function setSuccess(map: Map<string, MulticallResult>, key: string, result: unknown): void {
  if (result === undefined) return;
  map.set(key, { status: 'success', result });
}

function hasSuccess(map: Map<string, MulticallResult>, key: string): boolean {
  const r = map.get(key);
  return !!r && r.status === 'success';
}

type AgentLensModuleStatus = {
  claimOk: boolean;
  mineCoreOk: boolean;
  furnaceOk: boolean;
  royaltiesOk: boolean;
  veOk: boolean;
  marketOk: boolean;
  lpVaultOk: boolean;
  dexOk: boolean;
};

type AgentLensUserModuleStatus = {
  mineCoreOk: boolean;
  royaltiesOk: boolean;
  veOk: boolean;
  marketOk: boolean;
  lpVaultOk: boolean;
  claimBalanceOk: boolean;
};

function parseAgentLensModuleStatus(raw: unknown): AgentLensModuleStatus {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    claimOk: asBool(obj?.claimOk ?? t[0]),
    mineCoreOk: asBool(obj?.mineCoreOk ?? t[1]),
    furnaceOk: asBool(obj?.furnaceOk ?? t[2]),
    royaltiesOk: asBool(obj?.royaltiesOk ?? t[3]),
    veOk: asBool(obj?.veOk ?? t[4]),
    marketOk: asBool(obj?.marketOk ?? t[5]),
    lpVaultOk: asBool(obj?.lpVaultOk ?? t[6]),
    dexOk: asBool(obj?.dexOk ?? t[7]),
  };
}

function parseAgentLensUserModuleStatus(raw: unknown): AgentLensUserModuleStatus {
  const obj = raw as any;
  const t = asTuple(raw);
  return {
    mineCoreOk: asBool(obj?.mineCoreOk ?? t[0]),
    royaltiesOk: asBool(obj?.royaltiesOk ?? t[1]),
    veOk: asBool(obj?.veOk ?? t[2]),
    marketOk: asBool(obj?.marketOk ?? t[3]),
    lpVaultOk: asBool(obj?.lpVaultOk ?? t[4]),
    claimBalanceOk: asBool(obj?.claimBalanceOk ?? t[5]),
  };
}

function recordAgentLensStatusFailures(
  failures: Array<{ key: string; error: string }>,
  prefix: string,
  status: Record<string, boolean>,
): void {
  for (const [key, ok] of Object.entries(status)) {
    if (!ok) failures.push({ key: `${prefix}.${key}`, error: 'AgentLens status flag false' });
  }
}

function asErrorString(err: unknown): string {
  return safeErrorString(err);
}

function seedFromAgentLensGlobal(
  raw: unknown,
  resultMap: Map<string, MulticallResult>,
  failures: Array<{ key: string; error: string }>,
): {
  blockNumber: bigint;
  blockTimestamp: bigint;
  seededAnyModule: boolean;
} {
  const gObj = raw as any;
  const gT = asTuple(raw);

  const blockNumber = asBigInt(gObj?.blockNumber ?? gT[0]);
  const blockTimestamp = asBigInt(gObj?.blockTimestamp ?? gT[1]);
  const status = parseAgentLensModuleStatus(gObj?.status ?? gT[11]);
  recordAgentLensStatusFailures(failures, 'AgentLens.readGlobalV1.status', status);
  let seededAnyModule = false;

  const claimRaw = gObj?.claim ?? gT[3];
  const claimObj = claimRaw as any;
  const claimT = asTuple(claimRaw);
  if (status.claimOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'claim.name', String(claimObj?.name ?? claimT[0] ?? ''));
    setSuccess(resultMap, 'claim.symbol', String(claimObj?.symbol ?? claimT[1] ?? ''));
    setSuccess(resultMap, 'claim.decimals', asNumber(claimObj?.decimals ?? claimT[2], 18));
    setSuccess(resultMap, 'claim.totalSupply', asBigInt(claimObj?.totalSupply ?? claimT[3]));
  }

  const mineRaw = gObj?.mineCore ?? gT[4];
  const mineObj = mineRaw as any;
  const mineT = asTuple(mineRaw);
  if (status.mineCoreOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'mine.currentKing', asAddress(mineObj?.currentKing ?? mineT[0]));
    setSuccess(resultMap, 'mine.currentReignId', asBigInt(mineObj?.currentReignId ?? mineT[1]));
    setSuccess(
      resultMap,
      'mine.currentReignStartTime',
      asBigInt(mineObj?.currentReignStartTime ?? mineT[2]),
    );
    setSuccess(
      resultMap,
      'mine.currentReignLastAccrualTime',
      asBigInt(mineObj?.currentReignLastAccrualTime ?? mineT[3]),
    );
    setSuccess(
      resultMap,
      'mine.currentTakeoverPrice',
      asBigInt(mineObj?.currentTakeoverPrice ?? mineT[4]),
    );
    setSuccess(resultMap, 'mine.referencePrice', asBigInt(mineObj?.referencePrice ?? mineT[5]));
    setSuccess(
      resultMap,
      'mine.emissionStartTime',
      asBigInt(mineObj?.emissionStartTime ?? mineT[6]),
    );
    setSuccess(
      resultMap,
      'mine.currentFurnaceEmissionRate',
      asBigInt(mineObj?.currentFurnaceEmissionRate ?? mineT[7]),
    );
    // King emission rate: prefer the `currentKingEmissionRate` field exposed by
    // AgentLens v2+. Fall back to `currentFurnaceEmissionRate * 10n` for older
    // AgentLens deployments that predate the field, mirroring the 10:1 invariant
    // pinned by testKingFurnaceLaunchRateRatioPinned. The fallback also covers
    // any transient manifest/AgentLens version skew during a rollout window —
    // the lens reader always writes a correct value regardless.
    setSuccess(
      resultMap,
      'mine.currentKingEmissionRate',
      mineObj?.currentKingEmissionRate !== undefined
        ? asBigInt(mineObj.currentKingEmissionRate)
        : asBigInt(mineObj?.currentFurnaceEmissionRate ?? mineT[7]) * 10n,
    );
    setSuccess(resultMap, 'mine.takeoversPaused', asBool(mineObj?.takeoversPaused ?? mineT[8]));
    setSuccess(resultMap, 'mine.configFrozen', asBool(mineObj?.configFrozen ?? mineT[9]));
    setSuccess(resultMap, 'mine.guardian', asAddress(mineObj?.guardian ?? mineT[10]));

    setSuccess(resultMap, 'mine.furnace', asAddress(mineObj?.furnace ?? mineT[14]));
    setSuccess(resultMap, 'mine.ve', asAddress(mineObj?.ve ?? mineT[12]));
    setSuccess(resultMap, 'mine.royalties', asAddress(mineObj?.royalties ?? mineT[13]));
    setSuccess(
      resultMap,
      'mine.entryTokenRegistry',
      asAddress(mineObj?.entryTokenRegistry ?? mineT[15]),
    );
    setSuccess(resultMap, 'mine.delegationHub', asAddress(mineObj?.delegationHub ?? mineT[16]));
    setSuccess(resultMap, 'mine.claimAllHelper', asAddress(mineObj?.claimAllHelper ?? mineT[17]));

    setSuccess(
      resultMap,
      'mine.currentReign.ethRecipient',
      asAddress(mineObj?.currentReignEthRecipient ?? mineT[18]),
    );
    setSuccess(
      resultMap,
      'mine.currentReign.claimRecipient',
      asAddress(mineObj?.currentReignClaimRecipient ?? mineT[19]),
    );

    setSuccess(
      resultMap,
      'mine.genesisKingClaimCollected',
      asBool(mineObj?.genesisKingClaimCollected ?? mineT[20]),
    );
    setSuccess(
      resultMap,
      'mine.genesisKingClaimMinted',
      asBigInt(mineObj?.genesisKingClaimMinted ?? mineT[21]),
    );
  }

  const furnaceRaw = gObj?.furnace ?? gT[5];
  const furnaceObj = furnaceRaw as any;
  const furnaceT = asTuple(furnaceRaw);
  if (status.furnaceOk) {
    seededAnyModule = true;
    setSuccess(
      resultMap,
      'furnace.lockingPaused',
      asBool(furnaceObj?.lockingPaused ?? furnaceT[0]),
    );
    setSuccess(resultMap, 'furnace.state', [
      asBigInt(furnaceObj?.reserve ?? furnaceT[1]),
      asBigInt(furnaceObj?.lockedSupply ?? furnaceT[2]),
      asBigInt(furnaceObj?.userSpotBonusBps ?? furnaceT[3]),
      asBigInt(furnaceObj?.lpTopupRateBps ?? furnaceT[4]),
      asBigInt(furnaceObj?.quoteUserBonusBps ?? furnaceT[5]),
      asBigInt(furnaceObj?.quoteLpTopupBps ?? furnaceT[6]),
      asBigInt(furnaceObj?.virtualDepth ?? furnaceT[7]),
      asBigInt(furnaceObj?.lastUpdate ?? furnaceT[8]),
    ]);
    setSuccess(resultMap, 'furnace.lpStreamState', [
      asBigInt(furnaceObj?.lpStreamRatePerSec ?? furnaceT[9]),
      asBigInt(furnaceObj?.lpStreamPeriodFinish ?? furnaceT[10]),
      asBigInt(furnaceObj?.lpStreamLastUpdate ?? furnaceT[11]),
      asBigInt(furnaceObj?.lpStreamRemaining ?? furnaceT[12]),
    ]);
  }

  const royaltiesRaw = gObj?.royalties ?? gT[6];
  const royaltiesObj = royaltiesRaw as any;
  const royaltiesT = asTuple(royaltiesRaw);
  if (status.royaltiesOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'roy.configFrozen', asBool(royaltiesObj?.configFrozen ?? royaltiesT[0]));
    setSuccess(resultMap, 'roy.ethPerVe', asBigInt(royaltiesObj?.ethPerVe ?? royaltiesT[1]));
    setSuccess(
      resultMap,
      'roy.pendingShareholderETH',
      asBigInt(royaltiesObj?.pendingShareholderETH ?? royaltiesT[2]),
    );
    setSuccess(resultMap, 'roy.ve', asAddress(royaltiesObj?.ve ?? royaltiesT[3]));
    setSuccess(resultMap, 'roy.furnace', asAddress(royaltiesObj?.furnace ?? royaltiesT[4]));
    setSuccess(resultMap, 'roy.mineCore', asAddress(royaltiesObj?.mineCore ?? royaltiesT[5]));
    setSuccess(resultMap, 'roy.mineMarket', asAddress(royaltiesObj?.mineMarket ?? royaltiesT[6]));
    setSuccess(
      resultMap,
      'roy.claimAllHelper',
      asAddress(royaltiesObj?.claimAllHelper ?? royaltiesT[7]),
    );
  }

  const veRaw = gObj?.ve ?? gT[7];
  const veObj = veRaw as any;
  const veT = asTuple(veRaw);
  if (status.veOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 've.totalLockedClaim', asBigInt(veObj?.totalLockedClaim ?? veT[0]));
    setSuccess(resultMap, 've.totalVeCached', asBigInt(veObj?.totalVeCached ?? veT[1]));
    setSuccess(resultMap, 've.totalVeCurrent', asBigInt(veObj?.totalVeCurrent ?? veT[2]));
    setSuccess(resultMap, 've.globalLastTs', asBigInt(veObj?.globalLastTs ?? veT[3]));
    setSuccess(resultMap, 've.furnace', asAddress(veObj?.furnace ?? veT[4]));
  }

  const marketRaw = gObj?.market ?? gT[8];
  const marketObj = marketRaw as any;
  const marketT = asTuple(marketRaw);
  if (status.marketOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'mkt.guardian', asAddress(marketObj?.guardian ?? marketT[0]));
    setSuccess(resultMap, 'mkt.tradingPaused', asBool(marketObj?.tradingPaused ?? marketT[1]));
    setSuccess(resultMap, 'mkt.configFrozen', asBool(marketObj?.configFrozen ?? marketT[2]));
    setSuccess(resultMap, 'mkt.nextOfferId', asBigInt(marketObj?.nextOfferId ?? marketT[3]));
    setSuccess(
      resultMap,
      'mkt.minBonusTargetEscrowBudget',
      asBigInt(marketObj?.minBonusTargetEscrowBudget ?? marketT[4]),
    );
    setSuccess(
      resultMap,
      'mkt.maxBonusTargetEscrowDiscountBps',
      asBigInt(marketObj?.maxBonusTargetEscrowDiscountBps ?? marketT[5]),
    );
  }

  const lpRaw = gObj?.lpVault ?? gT[9];
  const lpObj = lpRaw as any;
  const lpT = asTuple(lpRaw);
  if (status.lpVaultOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'lp.furnace', asAddress(lpObj?.furnace ?? lpT[0]));
    setSuccess(resultMap, 'lp.totalStaked', asBigInt(lpObj?.totalStaked ?? lpT[1]));
    setSuccess(
      resultMap,
      'lp.rewardPerTokenStored',
      asBigInt(lpObj?.rewardPerTokenStored ?? lpT[2]),
    );
    setSuccess(
      resultMap,
      'lp.accountedRewardBalance',
      asBigInt(lpObj?.accountedRewardBalance ?? lpT[3]),
    );
    setSuccess(resultMap, 'lp.queuedRewards', asBigInt(lpObj?.queuedRewards ?? lpT[4]));
    setSuccess(resultMap, 'lp.lastFeeHarvestTs', asBigInt(lpObj?.lastFeeHarvestTs ?? lpT[5]));
    setSuccess(
      resultMap,
      'lp.totalClaimRewardsFundedFromFurnace',
      asBigInt(lpObj?.totalClaimRewardsFundedFromFurnace ?? lpT[6]),
    );
    setSuccess(
      resultMap,
      'lp.totalClaimRewardsFundedFromVaultFees',
      asBigInt(lpObj?.totalClaimRewardsFundedFromVaultFees ?? lpT[7]),
    );
    setSuccess(
      resultMap,
      'lp.totalClaimRewardsClaimed',
      asBigInt(lpObj?.totalClaimRewardsClaimed ?? lpT[8]),
    );
    setSuccess(
      resultMap,
      'lp.totalClaimRewardsLockedViaFurnace',
      asBigInt(lpObj?.totalClaimRewardsLockedViaFurnace ?? lpT[9]),
    );
  }

  const dexRaw = gObj?.dex ?? gT[10];
  const dexObj = dexRaw as any;
  const dexT = asTuple(dexRaw);
  if (status.dexOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'dex.aerodromeRouter', asAddress(dexObj?.aerodromeRouter ?? dexT[0]));
    setSuccess(resultMap, 'dex.aerodromeFactory', asAddress(dexObj?.aerodromeFactory ?? dexT[1]));
    setSuccess(resultMap, 'dex.wrappedNative', asAddress(dexObj?.wrappedNative ?? dexT[2]));
  }

  return { blockNumber, blockTimestamp, seededAnyModule };
}

function seedFromAgentLensUser(
  raw: unknown,
  resultMap: Map<string, MulticallResult>,
  failures: Array<{ key: string; error: string }>,
): { ethBalance: bigint; seededAnyModule: boolean } {
  const uObj = raw as any;
  const uT = asTuple(raw);
  const status = parseAgentLensUserModuleStatus(uObj?.status ?? uT[11]);
  recordAgentLensStatusFailures(failures, 'AgentLens.readUserV1.status', status);
  let seededAnyModule = false;

  const ethBalance = asBigInt(uObj?.ethBalance ?? uT[4]);
  if (status.claimBalanceOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'user.claimBalance', asBigInt(uObj?.claimBalance ?? uT[5]));
  }

  const mineRaw = uObj?.mineCore ?? uT[6];
  const mineObj = mineRaw as any;
  const mineT = asTuple(mineRaw);
  if (status.mineCoreOk) {
    seededAnyModule = true;
    setSuccess(
      resultMap,
      'user.mine.kingEthBalance',
      asBigInt(mineObj?.kingEthBalance ?? mineT[0]),
    );
    setSuccess(
      resultMap,
      'user.mine.refundEthBalance',
      asBigInt(mineObj?.refundEthBalance ?? mineT[1]),
    );

    const autoRaw = mineObj?.kingAutoLockConfig ?? mineT[2];
    const autoObj = autoRaw as any;
    const autoT = asTuple(autoRaw);

    setSuccess(resultMap, 'user.mine.autoLockConfig', [
      asBool(autoObj?.enabled ?? autoT[0]),
      asBigInt(autoObj?.targetTokenId ?? autoT[1]),
      asBigInt(autoObj?.pinnedTokenId ?? autoT[2]),
      asNumber(autoObj?.durationSeconds ?? autoT[3]),
      asBool(autoObj?.createAutoMax ?? autoT[4]),
      asBigInt(autoObj?.minVeOut ?? autoT[5]),
    ]);
  }

  const royRaw = uObj?.royalties ?? uT[7];
  const royObj = royRaw as any;
  const royT = asTuple(royRaw);
  if (status.royaltiesOk) {
    seededAnyModule = true;
    const shareholderRaw = royObj?.shareholderState ?? royT[0];
    const shareholderObj = shareholderRaw as any;
    const shareholderT = asTuple(shareholderRaw);

    setSuccess(resultMap, 'user.roy.shareholderState', [
      asBigInt(shareholderObj?.claimable ?? shareholderT[0]),
      asBigInt(shareholderObj?.userVe ?? shareholderT[1]),
      asBigInt(shareholderObj?.paid ?? shareholderT[2]),
    ]);

    const royAutoRaw = royObj?.autoCompoundConfig ?? royT[1];
    const royAutoObj = royAutoRaw as any;
    const royAutoT = asTuple(royAutoRaw);

    setSuccess(resultMap, 'user.roy.autoCompoundConfig', [
      asBool(royAutoObj?.enabled ?? royAutoT[0]),
      asBool(royAutoObj?.paused ?? royAutoT[1]),
      asBigInt(royAutoObj?.tokenId ?? royAutoT[2]),
      asBigInt(royAutoObj?.durationSeconds ?? royAutoT[3]),
      asNumber(royAutoObj?.minCadenceSeconds ?? royAutoT[4]),
      asBigInt(royAutoObj?.minEthToCompound ?? royAutoT[5]),
      asNumber(royAutoObj?.lastCompoundTs ?? royAutoT[6]),
    ]);
  }

  const veRaw = uObj?.ve ?? uT[8];
  const veObj = veRaw as any;
  const veT = asTuple(veRaw);
  if (status.veOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'user.ve.nftBalance', asBigInt(veObj?.nftBalance ?? veT[0]));
    setSuccess(resultMap, 'user.ve.veBalance', asBigInt(veObj?.veBalance ?? veT[1]));
  }

  const marketRaw = uObj?.market ?? uT[9];
  const marketObj = marketRaw as any;
  const marketT = asTuple(marketRaw);
  if (status.marketOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'user.mkt.listingIds', (marketObj?.listingIds ?? marketT[0]) as any);
    setSuccess(resultMap, 'user.mkt.offerIds', (marketObj?.offerIds ?? marketT[1]) as any);
  }

  const lpRaw = uObj?.lpVault ?? uT[10];
  const lpObj = lpRaw as any;
  const lpT = asTuple(lpRaw);
  if (status.lpVaultOk) {
    seededAnyModule = true;
    setSuccess(resultMap, 'user.lp.stakedBalance', asBigInt(lpObj?.stakedBalance ?? lpT[0]));
    setSuccess(resultMap, 'user.lp.earned', asBigInt(lpObj?.earned ?? lpT[1]));
    setSuccess(resultMap, 'user.lp.rewards', asBigInt(lpObj?.rewards ?? lpT[2]));
    setSuccess(resultMap, 'user.lp.unbondCount', asBigInt(lpObj?.unbondCount ?? lpT[3]));

    const lpAutoRaw = lpObj?.autoCompoundConfig ?? lpT[4];
    const lpAutoObj = lpAutoRaw as any;
    const lpAutoT = asTuple(lpAutoRaw);

    setSuccess(resultMap, 'user.lp.autoCompoundConfig', [
      asBool(lpAutoObj?.enabled ?? lpAutoT[0]),
      asBool(lpAutoObj?.paused ?? lpAutoT[1]),
      asBigInt(lpAutoObj?.tokenId ?? lpAutoT[2]),
      asBigInt(lpAutoObj?.durationSeconds ?? lpAutoT[3]),
    ]);
  }

  return { ethBalance, seededAnyModule };
}

/**
 * Builds a broad "lens" snapshot for agents using view calls only (no protocol changes).
 *
 * Notes
 * - Uses `publicClient.multicall` when available; falls back to sequential `readContract`.
 * - BigInt values are returned as BigInt in the object. Use `stringifySnapshot` for JSON.
 */
export async function getGameStateSnapshot(opts: SnapshotOptions): Promise<ClaimRushSnapshot> {
  const abiNetwork = opts.abiNetwork;

  // Validate user address if provided
  if (opts.user !== undefined && !isAddress(opts.user)) {
    throw new Error(
      `Invalid user address: "${opts.user}". ` +
        `Expected a valid Ethereum address (0x followed by 40 hex characters). ` +
        `Omit USER_ADDRESS to run without user-specific data.`,
    );
  }

  const addr = (name: keyof DeploymentManifest['contracts']): Address => {
    const a = opts.manifest.contracts[name]?.address;
    if (typeof a !== 'string' || !isAddress(a))
      throw new Error(`Invalid address for manifest.contracts.${String(name)}`);
    return a;
  };

  const addresses: Record<string, Address> = {};
  for (const [k, v] of Object.entries(opts.manifest.contracts)) {
    if (typeof v?.address === 'string' && isAddress(v.address)) addresses[k] = v.address;
  }

  const user = opts.user;
  const includeUserMarketDetails = opts.includeUserMarketDetails ?? true;
  const maxUserMarketItems = opts.maxUserMarketItems ?? 100;

  const failures: Array<{ key: string; error: string }> = [];
  const resultMap = new Map<string, MulticallResult>();

  // Option A: Prefer onchain AgentLens when present. Fallback to the original multicall snapshot on failure.
  const preferOnchainLens = opts.preferOnchainLens ?? true;
  const zeroAddress: Address = '0x0000000000000000000000000000000000000000';
  const lensAddressCandidate = opts.agentLensAddress ?? addresses['AgentLens'];
  const lensAddress =
    typeof lensAddressCandidate === 'string' &&
    isAddress(lensAddressCandidate) &&
    lensAddressCandidate !== zeroAddress
      ? (lensAddressCandidate as Address)
      : undefined;

  let usedOnchainLensGlobal = false;
  let usedOnchainLensUser = false;
  let lensUserEthBalance: bigint | undefined;

  let blockNumber = 0n;
  let blockTimestamp = 0n;

  if (preferOnchainLens && lensAddress) {
    try {
      const agentLensAbi = loadAbi({
        contractName: 'AgentLens',
        abiNetwork,
        repoRoot: opts.repoRoot,
      });
      const globalRaw = await opts.publicClient.readContract({
        address: lensAddress,
        abi: agentLensAbi,
        functionName: 'readGlobalV1',
      });

      const seeded = seedFromAgentLensGlobal(globalRaw, resultMap, failures);
      blockNumber = seeded.blockNumber;
      blockTimestamp = seeded.blockTimestamp;
      usedOnchainLensGlobal = seeded.seededAnyModule;

      if (user) {
        try {
          const userRaw = await opts.publicClient.readContract({
            address: lensAddress,
            abi: agentLensAbi,
            functionName: 'readUserV1',
            args: [user],
          });
          const seededUser = seedFromAgentLensUser(userRaw, resultMap, failures);
          lensUserEthBalance = seededUser.ethBalance;
          usedOnchainLensUser = seededUser.seededAnyModule;
        } catch (err) {
          failures.push({ key: 'AgentLens.readUserV1', error: asErrorString(err) });
        }
      }
    } catch (err) {
      failures.push({ key: 'AgentLens.readGlobalV1', error: asErrorString(err) });
    }
  }

  if (!usedOnchainLensGlobal) {
    const latestBlock = await opts.publicClient.getBlock();
    blockNumber = latestBlock.number ?? 0n;
    blockTimestamp = latestBlock.timestamp;
  }

  const abis = {
    ClaimToken: loadAbi({ contractName: 'ClaimToken', abiNetwork, repoRoot: opts.repoRoot }),
    VeClaimNFT: loadAbi({ contractName: 'VeClaimNFT', abiNetwork, repoRoot: opts.repoRoot }),
    MineCore: loadAbi({ contractName: 'MineCore', abiNetwork, repoRoot: opts.repoRoot }),
    Furnace: loadAbi({ contractName: 'Furnace', abiNetwork, repoRoot: opts.repoRoot }),
    ShareholderRoyalties: loadAbi({
      contractName: 'ShareholderRoyalties',
      abiNetwork,
      repoRoot: opts.repoRoot,
    }),
    MarketRouter: loadAbi({ contractName: 'MarketRouter', abiNetwork, repoRoot: opts.repoRoot }),
    LpStakingVault7D: loadAbi({
      contractName: 'LpStakingVault7D',
      abiNetwork,
      repoRoot: opts.repoRoot,
    }),
    EntryTokenRegistry: loadAbi({
      contractName: 'EntryTokenRegistry',
      abiNetwork,
      repoRoot: opts.repoRoot,
    }),
    DexAdapter: loadAbi({ contractName: 'DexAdapter', abiNetwork, repoRoot: opts.repoRoot }),
    LaunchController: loadAbi({
      contractName: 'LaunchController',
      abiNetwork,
      repoRoot: opts.repoRoot,
    }),
    GenesisLPVault24M: loadAbi({
      contractName: 'GenesisLPVault24M',
      abiNetwork,
      repoRoot: opts.repoRoot,
    }),
    ClaimAllHelper: loadAbi({
      contractName: 'ClaimAllHelper',
      abiNetwork,
      repoRoot: opts.repoRoot,
    }),
  } as const;

  const phase1Calls: CallSpec[] = [
    // Claim token
    {
      key: 'claim.name',
      call: { address: addr('ClaimToken'), abi: abis.ClaimToken, functionName: 'name' },
    },
    {
      key: 'claim.symbol',
      call: { address: addr('ClaimToken'), abi: abis.ClaimToken, functionName: 'symbol' },
    },
    {
      key: 'claim.decimals',
      call: { address: addr('ClaimToken'), abi: abis.ClaimToken, functionName: 'decimals' },
    },
    {
      key: 'claim.totalSupply',
      call: { address: addr('ClaimToken'), abi: abis.ClaimToken, functionName: 'totalSupply' },
    },

    // MineCore
    {
      key: 'mine.currentKing',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'currentKing' },
    },
    {
      key: 'mine.currentReignId',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'currentReignId' },
    },
    {
      key: 'mine.currentReignStartTime',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'currentReignStartTime',
      },
    },
    {
      key: 'mine.currentReignLastAccrualTime',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'currentReignLastAccrualTime',
      },
    },
    {
      key: 'mine.takeoversPaused',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'takeoversPaused' },
    },
    {
      key: 'mine.currentTakeoverPrice',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'getCurrentTakeoverPrice',
      },
    },
    {
      key: 'mine.referencePrice',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'referencePrice' },
    },
    {
      key: 'mine.emissionStartTime',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'emissionStartTime' },
    },
    {
      key: 'mine.currentFurnaceEmissionRate',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'getCurrentFurnaceEmissionRate',
      },
    },
    {
      key: 'mine.genesisAccrualDuration',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'GENESIS_ACCRUAL_DURATION',
      },
    },
    {
      key: 'mine.genesisKingClaimMinted',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'genesisKingClaimMinted',
      },
    },
    {
      key: 'mine.genesisKingClaimCollected',
      call: {
        address: addr('MineCore'),
        abi: abis.MineCore,
        functionName: 'genesisKingClaimCollected',
      },
    },
    {
      key: 'mine.configFrozen',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'configFrozen' },
    },
    {
      key: 'mine.guardian',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'guardian' },
    },
    {
      key: 'mine.furnace',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'furnace' },
    },
    { key: 'mine.ve', call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 've' } },
    {
      key: 'mine.royalties',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'royalties' },
    },
    {
      key: 'mine.entryTokenRegistry',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'entryTokenRegistry' },
    },
    {
      key: 'mine.delegationHub',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'delegationHub' },
    },
    {
      key: 'mine.claimAllHelper',
      call: { address: addr('MineCore'), abi: abis.MineCore, functionName: 'claimAllHelper' },
    },

    // Furnace
    {
      key: 'furnace.state',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'getFurnaceState' },
    },
    {
      key: 'furnace.lockingPaused',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'lockingPaused' },
    },
    {
      key: 'furnace.furnaceReserve',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'furnaceReserve' },
    },
    {
      key: 'furnace.bonusVirtualDepth',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'bonusVirtualDepth' },
    },
    {
      key: 'furnace.capInflowPerDay',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'getCapInflowPerDay' },
    },
    {
      key: 'furnace.furnaceInflowPerDay',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'getFurnaceInflowPerDay' },
    },
    {
      key: 'furnace.lpOverflowDripPerDay',
      call: {
        address: addr('Furnace'),
        abi: abis.Furnace,
        functionName: 'getLpOverflowDripPerDay',
      },
    },
    {
      key: 'furnace.lpSaleRewardCapPerDay',
      call: {
        address: addr('Furnace'),
        abi: abis.Furnace,
        functionName: 'getLpSaleRewardCapPerDay',
      },
    },
    {
      key: 'furnace.lpSaleRewardCapRemaining',
      call: {
        address: addr('Furnace'),
        abi: abis.Furnace,
        functionName: 'getLpSaleRewardCapRemaining',
      },
    },
    {
      key: 'furnace.lpSaleRewardFundedToday',
      call: {
        address: addr('Furnace'),
        abi: abis.Furnace,
        functionName: 'getLpSaleRewardFundedToday',
      },
    },
    {
      key: 'furnace.lpStreamState',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'getLpStreamState' },
    },
    {
      key: 'furnace.sellImpactVolume',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'sellImpactVolume' },
    },
    {
      key: 'furnace.lastBonusUpdate',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'lastBonusUpdate' },
    },
    {
      key: 'furnace.lastSellImpactUpdate',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'lastSellImpactUpdate' },
    },
    {
      key: 'furnace.configFrozen',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'configFrozen' },
    },
    {
      key: 'furnace.deploymentTime',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'deploymentTime' },
    },
    {
      key: 'furnace.guardian',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'guardian' },
    },
    {
      key: 'furnace.mineCore',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'mineCore' },
    },
    {
      key: 'furnace.mineMarket',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'mineMarket' },
    },
    {
      key: 'furnace.lpRewardsVault',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'lpRewardsVault' },
    },
    {
      key: 'furnace.entryTokenRegistry',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'entryTokenRegistry' },
    },
    {
      key: 'furnace.delegationHub',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'delegationHub' },
    },
    {
      key: 'furnace.furnaceQuoter',
      call: { address: addr('Furnace'), abi: abis.Furnace, functionName: 'furnaceQuoter' },
    },

    // Royalties
    {
      key: 'roy.ethPerVe',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'ethPerVe',
      },
    },
    {
      key: 'roy.pendingShareholderETH',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'pendingShareholderETH',
      },
    },
    {
      key: 'roy.configFrozen',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'configFrozen',
      },
    },
    {
      key: 'roy.mineCore',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'mineCore',
      },
    },
    {
      key: 'roy.mineMarket',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'mineMarket',
      },
    },
    {
      key: 'roy.furnace',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'furnace',
      },
    },
    {
      key: 'roy.ve',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 've',
      },
    },
    {
      key: 'roy.claimAllHelper',
      call: {
        address: addr('ShareholderRoyalties'),
        abi: abis.ShareholderRoyalties,
        functionName: 'claimAllHelper',
      },
    },

    // ve
    {
      key: 've.name',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'name' },
    },
    {
      key: 've.symbol',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'symbol' },
    },
    {
      key: 've.totalLockedClaim',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'totalLockedClaim' },
    },
    {
      key: 've.totalVeCached',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'totalVeCached' },
    },
    {
      key: 've.totalVeCurrent',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'totalVeCurrent' },
    },
    {
      key: 've.globalLastTs',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'globalLastTs' },
    },
    {
      key: 've.claimToken',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'claimToken' },
    },
    {
      key: 've.furnace',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'furnace' },
    },
    {
      key: 've.mineMarket',
      call: { address: addr('VeClaimNFT'), abi: abis.VeClaimNFT, functionName: 'mineMarket' },
    },

    // Market
    {
      key: 'mkt.tradingPaused',
      call: {
        address: addr('MarketRouter'),
        abi: abis.MarketRouter,
        functionName: 'tradingPaused',
      },
    },
    {
      key: 'mkt.nextOfferId',
      call: { address: addr('MarketRouter'), abi: abis.MarketRouter, functionName: 'nextOfferId' },
    },
    {
      key: 'mkt.minBonusTargetEscrowBudget',
      call: {
        address: addr('MarketRouter'),
        abi: abis.MarketRouter,
        functionName: 'minBonusTargetEscrowBudget',
      },
    },
    {
      key: 'mkt.maxBonusTargetEscrowDiscountBps',
      call: {
        address: addr('MarketRouter'),
        abi: abis.MarketRouter,
        functionName: 'maxBonusTargetEscrowDiscountBps',
      },
    },
    {
      key: 'mkt.guardian',
      call: { address: addr('MarketRouter'), abi: abis.MarketRouter, functionName: 'guardian' },
    },
    {
      key: 'mkt.configFrozen',
      call: { address: addr('MarketRouter'), abi: abis.MarketRouter, functionName: 'configFrozen' },
    },
    {
      key: 'mkt.claim',
      call: { address: addr('MarketRouter'), abi: abis.MarketRouter, functionName: 'claim' },
    },
    {
      key: 'mkt.ve',
      call: { address: addr('MarketRouter'), abi: abis.MarketRouter, functionName: 've' },
    },
    {
      key: 'mkt.royalties',
      call: { address: addr('MarketRouter'), abi: abis.MarketRouter, functionName: 'royalties' },
    },

    // LP vault 7D
    {
      key: 'lp.lpToken',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'lpToken',
      },
    },
    {
      key: 'lp.weth',
      call: { address: addr('LpStakingVault7D'), abi: abis.LpStakingVault7D, functionName: 'weth' },
    },
    {
      key: 'lp.ve',
      call: { address: addr('LpStakingVault7D'), abi: abis.LpStakingVault7D, functionName: 've' },
    },
    {
      key: 'lp.furnace',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'furnace',
      },
    },
    {
      key: 'lp.totalStaked',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'totalStaked',
      },
    },
    {
      key: 'lp.queuedRewards',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'queuedRewards',
      },
    },
    {
      key: 'lp.rewardPerTokenStored',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'rewardPerTokenStored',
      },
    },
    {
      key: 'lp.lastFeeHarvestTs',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'lastFeeHarvestTs',
      },
    },
    {
      key: 'lp.accountedRewardBalance',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'accountedRewardBalance',
      },
    },
    {
      key: 'lp.totalClaimRewardsClaimed',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'totalClaimRewardsClaimed',
      },
    },
    {
      key: 'lp.totalClaimRewardsFundedFromFurnace',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'totalClaimRewardsFundedFromFurnace',
      },
    },
    {
      key: 'lp.totalClaimRewardsFundedFromVaultFees',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'totalClaimRewardsFundedFromVaultFees',
      },
    },
    {
      key: 'lp.totalClaimRewardsLockedViaFurnace',
      call: {
        address: addr('LpStakingVault7D'),
        abi: abis.LpStakingVault7D,
        functionName: 'totalClaimRewardsLockedViaFurnace',
      },
    },

    // Registries
    {
      key: 'reg.furnace.routerConfig',
      call: {
        address: addr('FurnaceEntryTokenRegistry'),
        abi: abis.EntryTokenRegistry,
        functionName: 'getRouterConfig',
      },
    },
    {
      key: 'reg.furnace.wethClaimHop',
      call: {
        address: addr('FurnaceEntryTokenRegistry'),
        abi: abis.EntryTokenRegistry,
        functionName: 'getWethClaimHop',
      },
    },
    {
      key: 'reg.takeover.routerConfig',
      call: {
        address: addr('MineCoreEntryTokenRegistry'),
        abi: abis.EntryTokenRegistry,
        functionName: 'getRouterConfig',
      },
    },
    {
      key: 'reg.takeover.wethClaimHop',
      call: {
        address: addr('MineCoreEntryTokenRegistry'),
        abi: abis.EntryTokenRegistry,
        functionName: 'getWethClaimHop',
      },
    },

    // DexAdapter
    {
      key: 'dex.wrappedNative',
      call: { address: addr('DexAdapter'), abi: abis.DexAdapter, functionName: 'wrappedNative' },
    },
    {
      key: 'dex.weth',
      call: { address: addr('DexAdapter'), abi: abis.DexAdapter, functionName: 'weth' },
    },
    {
      key: 'dex.aerodromeRouter',
      call: { address: addr('DexAdapter'), abi: abis.DexAdapter, functionName: 'aerodromeRouter' },
    },
    {
      key: 'dex.aerodromeFactory',
      call: { address: addr('DexAdapter'), abi: abis.DexAdapter, functionName: 'aerodromeFactory' },
    },
    {
      key: 'dex.defaultFactory',
      call: { address: addr('DexAdapter'), abi: abis.DexAdapter, functionName: 'defaultFactory' },
    },

    // LaunchController
    {
      key: 'launch.genesisFinalized',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'genesisFinalized',
      },
    },
    {
      key: 'launch.genesisFinalizedAt',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'genesisFinalizedAt',
      },
    },
    {
      key: 'launch.genesisClaimMinted',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'genesisClaimMinted',
      },
    },
    {
      key: 'launch.genesisLpMinted',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'genesisLpMinted',
      },
    },
    {
      key: 'launch.expectedPool',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'expectedPool',
      },
    },
    {
      key: 'launch.genesisLpVault',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'genesisLpVault',
      },
    },
    {
      key: 'launch.claim',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'claim',
      },
    },
    {
      key: 'launch.mineCore',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'mineCore',
      },
    },
    {
      key: 'launch.weth',
      call: { address: addr('LaunchController'), abi: abis.LaunchController, functionName: 'weth' },
    },
    {
      key: 'launch.aerodromeRouter',
      call: {
        address: addr('LaunchController'),
        abi: abis.LaunchController,
        functionName: 'aerodromeRouter',
      },
    },

    // Genesis LP Vault 24M
    {
      key: 'genlp.pool',
      call: {
        address: addr('GenesisLPVault24M'),
        abi: abis.GenesisLPVault24M,
        functionName: 'pool',
      },
    },
    {
      key: 'genlp.lpWithdrawRecipient',
      call: {
        address: addr('GenesisLPVault24M'),
        abi: abis.GenesisLPVault24M,
        functionName: 'lpWithdrawRecipient',
      },
    },
    {
      key: 'genlp.lpLockedAmount',
      call: {
        address: addr('GenesisLPVault24M'),
        abi: abis.GenesisLPVault24M,
        functionName: 'lpLockedAmount',
      },
    },
    {
      key: 'genlp.lockStartTime',
      call: {
        address: addr('GenesisLPVault24M'),
        abi: abis.GenesisLPVault24M,
        functionName: 'lockStartTime',
      },
    },
    {
      key: 'genlp.unlockTime',
      call: {
        address: addr('GenesisLPVault24M'),
        abi: abis.GenesisLPVault24M,
        functionName: 'unlockTime',
      },
    },
    {
      key: 'genlp.initialLockDuration',
      call: {
        address: addr('GenesisLPVault24M'),
        abi: abis.GenesisLPVault24M,
        functionName: 'INITIAL_LOCK_DURATION',
      },
    },
  ];

  if (user) {
    phase1Calls.push(
      // User balances
      {
        key: 'user.claimBalance',
        call: {
          address: addr('ClaimToken'),
          abi: abis.ClaimToken,
          functionName: 'balanceOf',
          args: [user],
        },
      },

      // User MineCore
      {
        key: 'user.mine.kingEthBalance',
        call: {
          address: addr('MineCore'),
          abi: abis.MineCore,
          functionName: 'kingEthBalance',
          args: [user],
        },
      },
      {
        key: 'user.mine.refundEthBalance',
        call: {
          address: addr('MineCore'),
          abi: abis.MineCore,
          functionName: 'refundEthBalance',
          args: [user],
        },
      },
      {
        key: 'user.mine.autoLockConfig',
        call: {
          address: addr('MineCore'),
          abi: abis.MineCore,
          functionName: 'getKingAutoLockConfig',
          args: [user],
        },
      },

      // User Royalties
      {
        key: 'user.roy.shareholderState',
        call: {
          address: addr('ShareholderRoyalties'),
          abi: abis.ShareholderRoyalties,
          functionName: 'getShareholderState',
          args: [user],
        },
      },
      {
        key: 'user.roy.autoCompoundConfig',
        call: {
          address: addr('ShareholderRoyalties'),
          abi: abis.ShareholderRoyalties,
          functionName: 'getAutoCompoundConfig',
          args: [user],
        },
      },

      // User ve
      {
        key: 'user.ve.nftBalance',
        call: {
          address: addr('VeClaimNFT'),
          abi: abis.VeClaimNFT,
          functionName: 'balanceOf',
          args: [user],
        },
      },
      {
        key: 'user.ve.veBalance',
        call: {
          address: addr('VeClaimNFT'),
          abi: abis.VeClaimNFT,
          functionName: 'veBalanceOf',
          args: [user],
        },
      },

      // User market
      {
        key: 'user.mkt.listingIds',
        call: {
          address: addr('MarketRouter'),
          abi: abis.MarketRouter,
          functionName: 'getUserListings',
          args: [user],
        },
      },
      {
        key: 'user.mkt.offerIds',
        call: {
          address: addr('MarketRouter'),
          abi: abis.MarketRouter,
          functionName: 'getUserBonusTargetEscrows',
          args: [user],
        },
      },

      // User LP
      {
        key: 'user.lp.stakedBalance',
        call: {
          address: addr('LpStakingVault7D'),
          abi: abis.LpStakingVault7D,
          functionName: 'stakedBalance',
          args: [user],
        },
      },
      {
        key: 'user.lp.earned',
        call: {
          address: addr('LpStakingVault7D'),
          abi: abis.LpStakingVault7D,
          functionName: 'earned',
          args: [user],
        },
      },
      {
        key: 'user.lp.rewards',
        call: {
          address: addr('LpStakingVault7D'),
          abi: abis.LpStakingVault7D,
          functionName: 'rewards',
          args: [user],
        },
      },
      {
        key: 'user.lp.unbondCount',
        call: {
          address: addr('LpStakingVault7D'),
          abi: abis.LpStakingVault7D,
          functionName: 'getUnbondCount',
          args: [user],
        },
      },
      {
        key: 'user.lp.autoCompoundConfig',
        call: {
          address: addr('LpStakingVault7D'),
          abi: abis.LpStakingVault7D,
          functionName: 'getAutoCompoundConfig',
          args: [user],
        },
      },
    );
  }

  const phase1CallsToRun = phase1Calls.filter((c) => !hasSuccess(resultMap, c.key));

  let phase1UsedMulticall = false;
  if (phase1CallsToRun.length > 0) {
    const phase1 = await safeMulticall({
      publicClient: opts.publicClient,
      calls: phase1CallsToRun,
      multicallAddress: opts.multicallAddress,
    });
    phase1UsedMulticall = phase1.usedMulticall;

    for (let i = 0; i < phase1CallsToRun.length; i++) {
      const key = phase1CallsToRun[i].key;
      const r = phase1.results[i];
      resultMap.set(key, r);
      if (r.status === 'failure') failures.push({ key, error: asErrorString((r as any).error) });
    }
  }

  // Phase 2: dynamic calls (current reign details, user market details, lock infos)
  const phase2Calls: CallSpec[] = [];

  const currentReignId = asBigInt(unwrap(resultMap.get('mine.currentReignId')));
  if (currentReignId > 0n) {
    phase2Calls.push(
      {
        key: 'mine.currentReign.info',
        call: {
          address: addr('MineCore'),
          abi: abis.MineCore,
          functionName: 'getReignInfo',
          args: [currentReignId],
        },
      },
      {
        key: 'mine.currentReign.ethRecipient',
        call: {
          address: addr('MineCore'),
          abi: abis.MineCore,
          functionName: 'reignEthRecipient',
          args: [currentReignId],
        },
      },
      {
        key: 'mine.currentReign.claimRecipient',
        call: {
          address: addr('MineCore'),
          abi: abis.MineCore,
          functionName: 'reignClaimRecipient',
          args: [currentReignId],
        },
      },
    );
  }

  let listingIds: bigint[] = [];
  let offerIds: bigint[] = [];
  if (user && includeUserMarketDetails) {
    const rawListings = unwrap(resultMap.get('user.mkt.listingIds'), []) as unknown;
    const rawOffers = unwrap(resultMap.get('user.mkt.offerIds'), []) as unknown;

    listingIds = (Array.isArray(rawListings) ? rawListings : [])
      .map((x) => asBigInt(x))
      .filter((x) => x > 0n);
    offerIds = (Array.isArray(rawOffers) ? rawOffers : [])
      .map((x) => asBigInt(x))
      .filter((x) => x > 0n);

    const listingIdsLimited = listingIds.slice(0, maxUserMarketItems);
    const offerIdsLimited = offerIds.slice(0, maxUserMarketItems);

    for (const tokenId of listingIdsLimited) {
      phase2Calls.push(
        {
          key: `user.mkt.listing.${tokenId}.info`,
          call: {
            address: addr('MarketRouter'),
            abi: abis.MarketRouter,
            functionName: 'getListing',
            args: [tokenId],
          },
        },
        {
          key: `user.mkt.listing.${tokenId}.lastActionBlock`,
          call: {
            address: addr('MarketRouter'),
            abi: abis.MarketRouter,
            functionName: 'lastListingActionBlock',
            args: [tokenId],
          },
        },
        {
          key: `user.mkt.listing.${tokenId}.lockInfo`,
          call: {
            address: addr('VeClaimNFT'),
            abi: abis.VeClaimNFT,
            functionName: 'getLockInfo',
            args: [tokenId],
          },
        },
      );
    }

    for (const offerId of offerIdsLimited) {
      phase2Calls.push(
        {
          key: `user.mkt.offer.${offerId}.escrow`,
          call: {
            address: addr('MarketRouter'),
            abi: abis.MarketRouter,
            functionName: 'getBonusTargetEscrow',
            args: [offerId],
          },
        },
        {
          key: `user.mkt.offer.${offerId}.config`,
          call: {
            address: addr('MarketRouter'),
            abi: abis.MarketRouter,
            functionName: 'bonusTargetConfigs',
            args: [offerId],
          },
        },
        {
          key: `user.mkt.offer.${offerId}.expiryBounds`,
          call: {
            address: addr('MarketRouter'),
            abi: abis.MarketRouter,
            functionName: 'getBonusTargetEscrowExpiryBounds',
            args: [offerId],
          },
        },
      );
    }
  }

  const phase2CallsToRun = phase2Calls.filter((c) => !hasSuccess(resultMap, c.key));

  let phase2UsedMulticall = false;
  if (phase2CallsToRun.length > 0) {
    const phase2 = await safeMulticall({
      publicClient: opts.publicClient,
      calls: phase2CallsToRun,
      multicallAddress: opts.multicallAddress,
    });
    phase2UsedMulticall = phase2.usedMulticall;

    for (let i = 0; i < phase2CallsToRun.length; i++) {
      const key = phase2CallsToRun[i].key;
      const r = phase2.results[i];
      resultMap.set(key, r);
      if (r.status === 'failure') failures.push({ key, error: asErrorString((r as any).error) });
    }
  }

  // User ETH balance is not a contract call, so keep it separate.
  const userEthBalance = user
    ? (lensUserEthBalance ?? (await opts.publicClient.getBalance({ address: user })))
    : 0n;

  const claimName = String(unwrap(resultMap.get('claim.name'), ''));
  const claimSymbol = String(unwrap(resultMap.get('claim.symbol'), ''));
  const claimDecimals = asNumber(unwrap(resultMap.get('claim.decimals'), 18));
  const claimTotalSupply = asBigInt(unwrap(resultMap.get('claim.totalSupply')));

  const furnaceState = parseFurnaceState(unwrap(resultMap.get('furnace.state')));
  const lpStreamState = parseLpStreamState(unwrap(resultMap.get('furnace.lpStreamState')));

  const regFurnaceRouterConfig = parseRouterConfig(
    unwrap(resultMap.get('reg.furnace.routerConfig')),
  );
  const regTakeoverRouterConfig = parseRouterConfig(
    unwrap(resultMap.get('reg.takeover.routerConfig')),
  );

  // Market user details
  const listings: UserMarketListingSnapshot[] = [];
  const offers: UserBonusTargetEscrowSnapshot[] = [];

  let listingsTruncated = false;
  let offersTruncated = false;

  if (user && includeUserMarketDetails) {
    const rawListings = unwrap(resultMap.get('user.mkt.listingIds'), []) as unknown;
    const rawOffers = unwrap(resultMap.get('user.mkt.offerIds'), []) as unknown;

    listingIds = (Array.isArray(rawListings) ? rawListings : [])
      .map((x) => asBigInt(x))
      .filter((x) => x > 0n);
    offerIds = (Array.isArray(rawOffers) ? rawOffers : [])
      .map((x) => asBigInt(x))
      .filter((x) => x > 0n);

    if (listingIds.length > maxUserMarketItems) listingsTruncated = true;
    if (offerIds.length > maxUserMarketItems) offersTruncated = true;

    for (const tokenId of listingIds.slice(0, maxUserMarketItems)) {
      const listingRaw = unwrap(resultMap.get(`user.mkt.listing.${tokenId}.info`));
      const blockRaw = unwrap(resultMap.get(`user.mkt.listing.${tokenId}.lastActionBlock`));
      const lockRaw = unwrap(resultMap.get(`user.mkt.listing.${tokenId}.lockInfo`));
      if (!listingRaw || !lockRaw) continue;
      listings.push({
        tokenId,
        listing: parseListing(listingRaw),
        lastListingActionBlock: asBigInt(blockRaw),
        lockInfo: parseLockInfo(lockRaw),
      });
    }

    for (const offerId of offerIds.slice(0, maxUserMarketItems)) {
      const escRaw = unwrap(resultMap.get(`user.mkt.offer.${offerId}.escrow`));
      const cfgRaw = unwrap(resultMap.get(`user.mkt.offer.${offerId}.config`));
      const expRaw = unwrap(resultMap.get(`user.mkt.offer.${offerId}.expiryBounds`));
      if (!escRaw || !cfgRaw || !expRaw) continue;
      const expT = asTuple(expRaw);
      offers.push({
        offerId,
        escrow: parseBonusTargetEscrow(escRaw),
        config: parseBonusTargetConfig(cfgRaw),
        expiryBounds: {
          createdAt: asBigInt(expT[0]),
          expiresAt: asBigInt(expT[1]),
          maxExpiresAt: asBigInt(expT[2]),
        },
      });
    }
  }

  // Current reign details
  let currentReign: ClaimRushSnapshot['mineCore']['currentReign'];
  if (currentReignId > 0n) {
    const infoRaw = unwrap(resultMap.get('mine.currentReign.info'));
    const ethRec = asAddress(unwrap(resultMap.get('mine.currentReign.ethRecipient')));
    const claimRec = asAddress(unwrap(resultMap.get('mine.currentReign.claimRecipient')));
    if (infoRaw) {
      currentReign = {
        ethRecipient: ethRec,
        claimRecipient: claimRec,
        info: parseMineCoreReignInfo(infoRaw),
      };
    }
  }

  const snapshot: ClaimRushSnapshot = {
    meta: {
      snapshotVersion: 'v1',
      manifestVersion: opts.manifest.version,
      chain: opts.manifest.chain,
      chainId: opts.manifest.chainId,
      blockNumber,
      blockTimestamp,
    },
    addresses,

    claim: {
      address: addr('ClaimToken'),
      name: claimName,
      symbol: claimSymbol,
      decimals: claimDecimals,
      totalSupply: claimTotalSupply,
    },

    mineCore: {
      address: addr('MineCore'),
      currentKing: asAddress(unwrap(resultMap.get('mine.currentKing'))),
      currentReignId,
      currentReignStartTime: asBigInt(unwrap(resultMap.get('mine.currentReignStartTime'))),
      currentReignLastAccrualTime: asBigInt(
        unwrap(resultMap.get('mine.currentReignLastAccrualTime')),
      ),
      takeoversPaused: asBool(unwrap(resultMap.get('mine.takeoversPaused'))),

      currentTakeoverPrice: asBigInt(unwrap(resultMap.get('mine.currentTakeoverPrice'))),
      referencePrice: asBigInt(unwrap(resultMap.get('mine.referencePrice'))),

      emissionStartTime: asBigInt(unwrap(resultMap.get('mine.emissionStartTime'))),
      currentFurnaceEmissionRate: asBigInt(
        unwrap(resultMap.get('mine.currentFurnaceEmissionRate')),
      ),
      // King emission rate: the lens reader (AgentLens path) always writes
      // 'mine.currentKingEmissionRate' to resultMap (using the lens field when
      // available, else `furnaceRate * 10n`). The multicall path (no-lens, e.g.
      // local devnet without AgentLens deployed) doesn't write the key because
      // MineCore doesn't expose a king-rate accessor — synthesize it here from
      // the Furnace rate that was fetched. The 10:1 invariant is pinned by
      // testKingFurnaceLaunchRateRatioPinned + testKingFurnaceFloorRatioPinnedWithin5Wei.
      currentKingEmissionRate: hasSuccess(resultMap, 'mine.currentKingEmissionRate')
        ? asBigInt(unwrap(resultMap.get('mine.currentKingEmissionRate')))
        : asBigInt(unwrap(resultMap.get('mine.currentFurnaceEmissionRate'))) * 10n,

      genesisAccrualDuration: asBigInt(unwrap(resultMap.get('mine.genesisAccrualDuration'))),
      genesisKingClaimMinted: asBigInt(unwrap(resultMap.get('mine.genesisKingClaimMinted'))),
      genesisKingClaimCollected: asBool(unwrap(resultMap.get('mine.genesisKingClaimCollected'))),

      configFrozen: asBool(unwrap(resultMap.get('mine.configFrozen'))),
      guardian: asAddress(unwrap(resultMap.get('mine.guardian'))),

      furnace: asAddress(unwrap(resultMap.get('mine.furnace'))),
      ve: asAddress(unwrap(resultMap.get('mine.ve'))),
      royalties: asAddress(unwrap(resultMap.get('mine.royalties'))),
      entryTokenRegistry: asAddress(unwrap(resultMap.get('mine.entryTokenRegistry'))),
      delegationHub: asAddress(unwrap(resultMap.get('mine.delegationHub'))),
      claimAllHelper: asAddress(unwrap(resultMap.get('mine.claimAllHelper'))),

      currentReign,
    },

    furnace: {
      address: addr('Furnace'),
      state: furnaceState,

      lockingPaused: asBool(unwrap(resultMap.get('furnace.lockingPaused'))),

      furnaceReserve: asBigInt(unwrap(resultMap.get('furnace.furnaceReserve'))),
      bonusVirtualDepth: asBigInt(unwrap(resultMap.get('furnace.bonusVirtualDepth'))),

      capInflowPerDay: asBigInt(unwrap(resultMap.get('furnace.capInflowPerDay'))),
      furnaceInflowPerDay: asBigInt(unwrap(resultMap.get('furnace.furnaceInflowPerDay'))),

      lpOverflowDripPerDay: asBigInt(unwrap(resultMap.get('furnace.lpOverflowDripPerDay'))),
      lpSaleRewardCapPerDay: asBigInt(unwrap(resultMap.get('furnace.lpSaleRewardCapPerDay'))),
      lpSaleRewardCapRemaining: asBigInt(unwrap(resultMap.get('furnace.lpSaleRewardCapRemaining'))),
      lpSaleRewardFundedToday: asBigInt(unwrap(resultMap.get('furnace.lpSaleRewardFundedToday'))),

      lpStreamState,

      sellImpactVolume: asBigInt(unwrap(resultMap.get('furnace.sellImpactVolume'))),
      lastBonusUpdate: asBigInt(unwrap(resultMap.get('furnace.lastBonusUpdate'))),
      lastSellImpactUpdate: asBigInt(unwrap(resultMap.get('furnace.lastSellImpactUpdate'))),

      configFrozen: asBool(unwrap(resultMap.get('furnace.configFrozen'))),
      deploymentTime: asBigInt(unwrap(resultMap.get('furnace.deploymentTime'))),
      guardian: asAddress(unwrap(resultMap.get('furnace.guardian'))),

      mineCore: asAddress(unwrap(resultMap.get('furnace.mineCore'))),
      mineMarket: asAddress(unwrap(resultMap.get('furnace.mineMarket'))),
      lpRewardsVault: asAddress(unwrap(resultMap.get('furnace.lpRewardsVault'))),
      entryTokenRegistry: asAddress(unwrap(resultMap.get('furnace.entryTokenRegistry'))),
      delegationHub: asAddress(unwrap(resultMap.get('furnace.delegationHub'))),
      furnaceQuoter: asAddress(unwrap(resultMap.get('furnace.furnaceQuoter'))),
    },

    royalties: {
      address: addr('ShareholderRoyalties'),
      ethPerVe: asBigInt(unwrap(resultMap.get('roy.ethPerVe'))),
      pendingShareholderETH: asBigInt(unwrap(resultMap.get('roy.pendingShareholderETH'))),
      configFrozen: asBool(unwrap(resultMap.get('roy.configFrozen'))),

      mineCore: asAddress(unwrap(resultMap.get('roy.mineCore'))),
      mineMarket: asAddress(unwrap(resultMap.get('roy.mineMarket'))),
      furnace: asAddress(unwrap(resultMap.get('roy.furnace'))),
      ve: asAddress(unwrap(resultMap.get('roy.ve'))),
      claimAllHelper: asAddress(unwrap(resultMap.get('roy.claimAllHelper'))),
    },

    ve: {
      address: addr('VeClaimNFT'),
      name: String(unwrap(resultMap.get('ve.name'), '')),
      symbol: String(unwrap(resultMap.get('ve.symbol'), '')),
      totalLockedClaim: asBigInt(unwrap(resultMap.get('ve.totalLockedClaim'))),
      totalVeCached: asBigInt(unwrap(resultMap.get('ve.totalVeCached'))),
      totalVeCurrent: asBigInt(unwrap(resultMap.get('ve.totalVeCurrent'))),
      globalLastTs: asBigInt(unwrap(resultMap.get('ve.globalLastTs'))),

      claimToken: asAddress(unwrap(resultMap.get('ve.claimToken'))),
      furnace: asAddress(unwrap(resultMap.get('ve.furnace'))),
      mineMarket: asAddress(unwrap(resultMap.get('ve.mineMarket'))),
    },

    market: {
      address: addr('MarketRouter'),
      tradingPaused: asBool(unwrap(resultMap.get('mkt.tradingPaused'))),
      nextOfferId: asBigInt(unwrap(resultMap.get('mkt.nextOfferId'))),

      minBonusTargetEscrowBudget: asBigInt(unwrap(resultMap.get('mkt.minBonusTargetEscrowBudget'))),
      maxBonusTargetEscrowDiscountBps: asBigInt(
        unwrap(resultMap.get('mkt.maxBonusTargetEscrowDiscountBps')),
      ),

      guardian: asAddress(unwrap(resultMap.get('mkt.guardian'))),
      configFrozen: asBool(unwrap(resultMap.get('mkt.configFrozen'))),

      claim: asAddress(unwrap(resultMap.get('mkt.claim'))),
      ve: asAddress(unwrap(resultMap.get('mkt.ve'))),
      royalties: asAddress(unwrap(resultMap.get('mkt.royalties'))),
    },

    lpVault7D: {
      address: addr('LpStakingVault7D'),
      lpToken: asAddress(unwrap(resultMap.get('lp.lpToken'))),
      weth: asAddress(unwrap(resultMap.get('lp.weth'))),
      ve: asAddress(unwrap(resultMap.get('lp.ve'))),
      furnace: asAddress(unwrap(resultMap.get('lp.furnace'))),

      totalStaked: asBigInt(unwrap(resultMap.get('lp.totalStaked'))),
      queuedRewards: asBigInt(unwrap(resultMap.get('lp.queuedRewards'))),
      rewardPerTokenStored: asBigInt(unwrap(resultMap.get('lp.rewardPerTokenStored'))),
      lastFeeHarvestTs: asBigInt(unwrap(resultMap.get('lp.lastFeeHarvestTs'))),
      accountedRewardBalance: asBigInt(unwrap(resultMap.get('lp.accountedRewardBalance'))),

      totalClaimRewardsClaimed: asBigInt(unwrap(resultMap.get('lp.totalClaimRewardsClaimed'))),
      totalClaimRewardsFundedFromFurnace: asBigInt(
        unwrap(resultMap.get('lp.totalClaimRewardsFundedFromFurnace')),
      ),
      totalClaimRewardsFundedFromVaultFees: asBigInt(
        unwrap(resultMap.get('lp.totalClaimRewardsFundedFromVaultFees')),
      ),
      totalClaimRewardsLockedViaFurnace: asBigInt(
        unwrap(resultMap.get('lp.totalClaimRewardsLockedViaFurnace')),
      ),
    },

    registries: {
      furnaceEntryTokenRegistry: {
        address: addr('FurnaceEntryTokenRegistry'),
        routerConfig: regFurnaceRouterConfig,
        wethClaimHop: asAddress(unwrap(resultMap.get('reg.furnace.wethClaimHop'))),
      },
      takeoverEntryTokenRegistry: {
        address: addr('MineCoreEntryTokenRegistry'),
        routerConfig: regTakeoverRouterConfig,
        wethClaimHop: asAddress(unwrap(resultMap.get('reg.takeover.wethClaimHop'))),
      },
    },

    dexAdapter: {
      address: addr('DexAdapter'),
      wrappedNative: asAddress(unwrap(resultMap.get('dex.wrappedNative'))),
      weth: asAddress(unwrap(resultMap.get('dex.weth'))),
      aerodromeRouter: asAddress(unwrap(resultMap.get('dex.aerodromeRouter'))),
      aerodromeFactory: asAddress(unwrap(resultMap.get('dex.aerodromeFactory'))),
      defaultFactory: asAddress(unwrap(resultMap.get('dex.defaultFactory'))),
    },

    launch: {
      address: addr('LaunchController'),
      genesisFinalized: asBool(unwrap(resultMap.get('launch.genesisFinalized'))),
      genesisFinalizedAt: asBigInt(unwrap(resultMap.get('launch.genesisFinalizedAt'))),

      genesisClaimMinted: asBigInt(unwrap(resultMap.get('launch.genesisClaimMinted'))),
      genesisLpMinted: asBigInt(unwrap(resultMap.get('launch.genesisLpMinted'))),

      expectedPool: asAddress(unwrap(resultMap.get('launch.expectedPool'))),
      genesisLpVault: asAddress(unwrap(resultMap.get('launch.genesisLpVault'))),

      claim: asAddress(unwrap(resultMap.get('launch.claim'))),
      mineCore: asAddress(unwrap(resultMap.get('launch.mineCore'))),
      weth: asAddress(unwrap(resultMap.get('launch.weth'))),
      aerodromeRouter: asAddress(unwrap(resultMap.get('launch.aerodromeRouter'))),
    },

    genesis: {
      lpVault24M: {
        address: addr('GenesisLPVault24M'),
        pool: asAddress(unwrap(resultMap.get('genlp.pool'))),
        lpWithdrawRecipient: asAddress(unwrap(resultMap.get('genlp.lpWithdrawRecipient'))),
        lpLockedAmount: asBigInt(unwrap(resultMap.get('genlp.lpLockedAmount'))),
        lockStartTime: asBigInt(unwrap(resultMap.get('genlp.lockStartTime'))),
        unlockTime: asBigInt(unwrap(resultMap.get('genlp.unlockTime'))),
        initialLockDuration: asBigInt(unwrap(resultMap.get('genlp.initialLockDuration'))),
      },
    },

    diagnostics: {
      usedOnchainLensGlobal,
      usedOnchainLensUser,
      onchainLensAddress: usedOnchainLensGlobal ? lensAddress : undefined,

      usedMulticall: phase1UsedMulticall || phase2UsedMulticall,
      failures,
    },
  };

  if (user) {
    const autoLock = unwrap(resultMap.get('user.mine.autoLockConfig'));
    const autoLockT = asTuple(autoLock);

    const shareholderState = unwrap(resultMap.get('user.roy.shareholderState'));
    const shareholderT = asTuple(shareholderState);

    const royAuto = unwrap(resultMap.get('user.roy.autoCompoundConfig'));
    const royAutoT = asTuple(royAuto);

    const lpAuto = unwrap(resultMap.get('user.lp.autoCompoundConfig'));
    const lpAutoT = asTuple(lpAuto);

    snapshot.user = {
      address: user,
      ethBalance: userEthBalance,
      claimBalance: asBigInt(unwrap(resultMap.get('user.claimBalance'))),

      mineCore: {
        kingEthBalance: asBigInt(unwrap(resultMap.get('user.mine.kingEthBalance'))),
        refundEthBalance: asBigInt(unwrap(resultMap.get('user.mine.refundEthBalance'))),
        kingAutoLockConfig: {
          enabled: asBool(autoLockT[0]),
          targetTokenId: asBigInt(autoLockT[1]),
          pinnedTokenId: asBigInt(autoLockT[2]),
          durationSeconds: asNumber(autoLockT[3]),
          createAutoMax: asBool(autoLockT[4]),
          minVeOut: asBigInt(autoLockT[5]),
        },
      },

      royalties: {
        shareholderState: {
          claimable: asBigInt(shareholderT[0]),
          userVe: asBigInt(shareholderT[1]),
          paid: asBigInt(shareholderT[2]),
        },
        autoCompoundConfig: {
          enabled: asBool(royAutoT[0]),
          paused: asBool(royAutoT[1]),
          tokenId: asBigInt(royAutoT[2]),
          durationSeconds: asBigInt(royAutoT[3]),
          minCadenceSeconds: asNumber(royAutoT[4]),
          minEthToCompound: asBigInt(royAutoT[5]),
          lastCompoundTs: asNumber(royAutoT[6]),
        },
      },

      ve: {
        nftBalance: asBigInt(unwrap(resultMap.get('user.ve.nftBalance'))),
        veBalance: asBigInt(unwrap(resultMap.get('user.ve.veBalance'))),
      },

      market: {
        listings,
        listingsTruncated,
        offers,
        offersTruncated,
      },

      lpVault7D: {
        stakedBalance: asBigInt(unwrap(resultMap.get('user.lp.stakedBalance'))),
        earned: asBigInt(unwrap(resultMap.get('user.lp.earned'))),
        rewards: asBigInt(unwrap(resultMap.get('user.lp.rewards'))),
        unbondCount: asBigInt(unwrap(resultMap.get('user.lp.unbondCount'))),
        autoCompoundConfig: {
          enabled: asBool(lpAutoT[0]),
          paused: asBool(lpAutoT[1]),
          tokenId: asBigInt(lpAutoT[2]),
          durationSeconds: asBigInt(lpAutoT[3]),
        },
      },
    };
  }

  return snapshot;
}

/** JSON.stringify helper that supports BigInt fields. */
export function stringifySnapshot(value: unknown, opts?: { pretty?: boolean }): string {
  const space = opts?.pretty ? 2 : undefined;
  return JSON.stringify(
    value,
    (_k, v) => {
      if (typeof v === 'bigint') return v.toString();
      return v;
    },
    space,
  );
}
