import type { Address, Hash } from 'viem';

import type { AgentStrategy } from './strategies.js';
import type { AgentExecutionSecurity } from './actionSecurity.js';

import type { AbiNetwork } from '../abis.js';
import type { ClaimRushErrorInfo } from '../errors.js';
import type { DeploymentManifest } from '../manifest.js';
import type { ClaimRushSnapshot } from '../snapshot.js';

export type LiveAgentOptions = {
  rpcUrl: string;

  /**
   * Optional runtime execution guardrails (allowlists, slippage/value caps, approval gates).
   *
   * These checks run inside the executor right before signing/sending transactions.
   */
  executionSecurity?: AgentExecutionSecurity;

  /**
   * Optional: start a small local HTTP monitor server.
   *
   * Endpoints:
   * - GET /health
   * - GET /state
   * - GET /recent/*
   *
   * Default: off.
   */
  monitorEnabled?: boolean;

  /** Default: 127.0.0.1 */
  monitorHost?: string;

  /** Default: 8787 (when enabled). */
  monitorPort?: number;

  /** Optional bearer token (Authorization: Bearer <token>) */
  monitorToken?: string;

  /** Max items stored per recent ring (default: 200). */
  monitorMaxRecent?: number;

  /**
   * Durable state directory for the agent (cursor, checkpoints, etc.).
   *
   * Default: out/agent-state/<chain>/<chainId>/<agent or agent-for-user>
   */
  stateDir?: string;

  /**
   * Event cursor rollback window (blocks) used to handle reorgs + ensure replay safety.
   *
   * Default: 20.
   */
  eventCursorRewindBlocks?: number;

  /**
   * Max recent event keys to persist for de-duplication within the rollback window.
   *
   * Default: 5_000.
   */
  eventCursorMaxRecentKeys?: number;

  /**
   * Optional private transaction RPC endpoint.
   *
   * When set, selected MEV-sensitive txs (takeovers + swaps) can be sent here.
   * All reads and simulations still use `rpcUrl`.
   */
  privateRpcUrl?: string;

  /**
   * Safety: require privateRpcUrl chainId to match rpcUrl chainId.
   *
   * Why: if privateRpcUrl points to a different chain, the agent can sign and broadcast
   * transactions to manifest addresses on the wrong chain (including EOAs), potentially
   * causing irreversible fund loss.
   *
   * Env: ALLOW_PRIVATE_RPC_CHAIN_ID_MISMATCH=1
   *
   * Default: false.
   */
  allowPrivateRpcChainIdMismatch?: boolean;

  /**
   * Private RPC routing mode.
   *
   * - 'off': ignore `privateRpcUrl` (everything uses `rpcUrl`)
   * - 'route': send allowlisted swap/takeover txs via `privateRpcUrl`, everything else via `rpcUrl`
   * - 'only': only allowlisted swap/takeover txs may be executed; all other actions are blocked
   *
   * Default: 'route' when `privateRpcUrl` is set, otherwise 'off'.
   */
  privateRpcMode?: 'off' | 'route' | 'only';

  /**
   * Optional: automatically insert required ERC20/veNFT approvals ahead of actions (plan expansion).
   *
   * This is useful for unattended agents that need to enter with tokens/CLAIM or take over with tokens.
   *
   * Safety defaults:
   * - disabled by default
   * - uses exact approvals by default (no infinite allowances)
   * - never runs when PRIVATE_RPC_MODE=only
   *
   * Env: AUTO_APPROVE_ENABLED=1
   *
   * Default: false.
   */
  autoApproveEnabled?: boolean;

  /**
   * Auto-approve sizing mode.
   *
   * - 'exact': approve exactly what's needed for the next action (default)
   * - 'max': approve MaxUint256 (convenient, higher risk)
   *
   * Env: AUTO_APPROVE_MODE=exact|max
   */
  autoApproveMode?: 'exact' | 'max';

  /**
   * Include veNFT (ERC721) approvals for MarketRouter (default: true).
   *
   * Env: AUTO_APPROVE_NFT=1
   */
  autoApproveIncludeNftApprovals?: boolean;

  /**
   * Optional: enable managed nonces for agent writes.
   *
   * When enabled, the agent assigns explicit nonces instead of relying on the RPC provider.
   * This is recommended when using both public + private RPC routes.
   *
   * Default: false (unless `txReplacementEnabled` is true).
   */
  txManageNonces?: boolean;

  /**
   * Optional: enable fee bump + replacement for stuck transactions.
   *
   * When enabled, the agent will re-broadcast the same nonce with higher fees if the tx is not mined
   * within `txReplacementTimeoutMs`.
   *
   * Default: false.
   */
  txReplacementEnabled?: boolean;

  /** Default: 45_000. */
  txReplacementTimeoutMs?: number;

  /** Default: 1_500. */
  txPollIntervalMs?: number;

  /** Default: 3. */
  txReplacementMaxAttempts?: number;

  /** Default: 12_500 (+25%). */
  txFeeBumpBps?: number;

  /**
   * Optional: enable a simple backoff/circuit breaker when writes repeatedly fail.
   *
   * When backoff is active, the agent continues to tick + simulate actions, but will not
   * broadcast writes until the cooldown expires.
   *
   * Default: true (only when execute=true).
   */
  backoffEnabled?: boolean;

  /** Default: 15_000. */
  backoffBaseCooldownMs?: number;

  /** Default: 300_000. */
  backoffMaxCooldownMs?: number;

  /** Default: 2 (exponential). */
  backoffMultiplier?: number;

  /** Default: 1 (enter backoff after one tx timeout). */
  backoffMaxConsecutiveTimeouts?: number;

  /** Default: 3 (enter backoff after three consecutive errors). */
  backoffMaxConsecutiveErrors?: number;

  /** Default: 120_000 (reset streak after 2 minutes of stability). */
  backoffResetAfterMs?: number;

  chain?: string;
  abiNetwork?: AbiNetwork;
  manifest?: DeploymentManifest;

  /**
   * Safety: require manifest.chainId to match the connected RPC chainId.
   *
   * Set true to bypass (useful for dev forks or custom chainId setups).
   *
   * Env: ALLOW_CHAIN_ID_MISMATCH=1
   *
   * Default: false.
   */
  allowChainIdMismatch?: boolean;

  // Account derivation (same rules as harness)
  actorIndex?: number;
  mnemonic?: string;
  privateKeysCsv?: string;

  /**
   * Safety: allow using the built-in DEFAULT_ANVIL_MNEMONIC on non-local chains.
   *
   * The Anvil mnemonic is publicly known and should only be used on local/dev chains.
   *
   * Env: ALLOW_INSECURE_DEFAULT_MNEMONIC=1
   *
   * Default: false.
   */
  allowInsecureDefaultMnemonic?: boolean;

  /**
   * Optional: run as a delegate for this user identity.
   *
   * When set to a different address than the derived actor, the agent will:
   * - read snapshots for `actingForUser`
   * - use protocol `...For(user)` entrypoints when available
   * - require an active DelegationHub session for any delegated action
   */
  actingForUser?: Address;

  // Loop control
  execute?: boolean;
  once?: boolean;
  tickSeconds?: number;
  maxActionsPerTick?: number;

  /**
   * Safety: cap the number of planned actions kept in memory/logged per tick.
   *
   * This prevents buggy or malicious strategy plugins from returning huge action arrays
   * that can cause OOM crashes or massive artifacts.
   *
   * Env: MAX_PLANNED_ACTIONS
   *
   * Default: 5_000 (hard max: 100_000).
   */
  maxPlannedActions?: number;

  // Event-driven wakeups
  useEvents?: boolean;
  eventPolling?: boolean;

  // Optional subgraph backfill for events
  subgraphUrl?: string;
  eventBackfill?: boolean;
  eventBackfillLimit?: number;

  /**
   * Optional base URL for an achievements HTTP API that exposes
   * `/api/achievements` and returns the live badge set for a user.
   *
   * When set, the agent polls this endpoint and emits `BADGE_UNLOCKED`
   * achievements for newly unlocked (or tier-upgraded) profile badges.
   * Any service that matches the documented JSON shape works; this SDK
   * does not hard-code a hosting provider. Leave unset to disable.
   */
  achievementsBaseUrl?: string;

  /** Default: 20s. */
  achievementsPollIntervalMs?: number;

  /** Default: 5s. */
  achievementsForceRefreshCooldownMs?: number;

  /** Default: 10s. */
  achievementsFetchTimeoutMs?: number;

  // ------------------------------------------------------------
  // Planning strategies (optional)
  // ------------------------------------------------------------

  /**
   * Optional: programmatic strategy plugins that propose actions each tick.
   *
   * When set (non-empty), the live agent will build its plan by running these
   * strategies instead of the default built-in policy (buildActionPlan).
   */
  strategies?: AgentStrategy[];

  // Strategy toggles
  enableFurnaceEntry?: boolean;
  enableTakeovers?: boolean;
  enableRoyaltiesClaim?: boolean;
  enableWithdrawals?: boolean;

  // Strategy params
  furnaceEthIn?: string;
  lockDurationDays?: number;
  targetTokenId?: bigint;
  createAutoMax?: boolean;
  slippageBps?: number;

  maxTakeoverEth?: string;
  takeoverCooldownSeconds?: number;

  minRoyaltiesEthToClaim?: string;
  minKingEthToWithdraw?: string;
  minRefundEthToWithdraw?: string;

  // Delegated safe maintenance (optional)
  enableSafeMaintenance?: boolean;
  /** Refresh/extend when remaining duration is below this threshold (days). */
  veExtendIfRemainingDays?: number;
  /** Extend by this many days. */
  veExtendByDays?: number;

  // Optional: desired config sync (delegated-only)
  kingAutoLockDesired?: {
    enabled: boolean;
    targetTokenId: bigint;
    durationSeconds: bigint;
    createAutoMax: boolean;
    minVeOut: bigint;
  };
  royaltiesAutoCompoundDesired?: {
    enabled: boolean;
    /** tokenId=0 means "use active lock" */
    tokenId: bigint;
    durationSeconds: bigint;
    minCadenceSeconds: bigint;
    minEthToCompound: bigint;
  };
  lpAutoCompoundDesired?: {
    enabled: boolean;
    /** tokenId=0 means "use active lock" */
    tokenId: bigint;
    durationSeconds: bigint;
  };

  /**
   * Optional Discord webhook URL for notifications (takeover events, errors, start/stop).
   *
   * Env: DISCORD_WEBHOOK_URL
   */
  discordWebhookUrl?: string;

  // Output
  outdir?: string;
  writeArtifacts?: boolean;

  /**
   * Optional: write per-tick records (snapshot + policy state) to support deterministic replay/backtests.
   *
   * Writes (when writeArtifacts=true):
   * - <outdir>/session.json
   * - <outdir>/ticks.jsonl
   *
   * Env: WRITE_TICK_RECORDS=1
   *
   * Default: false.
   */
  writeTickRecords?: boolean;
};

export type AgentAction =
  | {
      kind: 'furnace.enterWithEth';
      ethIn: bigint;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      /** Delegated Furnace entry: caller pays ETH, `user` receives the ve lock. */
      kind: 'furnace.enterWithEthFor';
      user: Address;
      ethIn: bigint;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      kind: 'furnace.enterWithClaim';
      claimIn: bigint;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      /** Delegated CLAIM entry: caller provides CLAIM, `user` receives the ve lock. */
      kind: 'furnace.enterWithClaimFromCallerFor';
      user: Address;
      claimIn: bigint;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      kind: 'furnace.enterWithToken';
      tokenIn: Address;
      amountIn: bigint;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      /** Delegated token entry: caller provides `tokenIn`, `user` receives the ve lock. */
      kind: 'furnace.enterWithTokenFromCallerFor';
      user: Address;
      tokenIn: Address;
      amountIn: bigint;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      kind: 'mineCore.takeover';
      price: bigint;
    }
  | {
      /** Delegated takeover: caller pays ETH, `newKing` becomes king identity. */
      kind: 'mineCore.takeoverFor';
      newKing: Address;
      price: bigint;
    }
  | {
      /**
       * Take over using an ERC20 entry token (MineCore swaps tokenIn -> ETH internally).
       *
       * The executor will:
       * - quote expected ETH out via MineCoreQuoter
       * - compute a slippage-adjusted minEthOut
       * - enforce minEthOut >= current takeoverPrice for safety
       */
      kind: 'mineCore.takeoverWithToken';
      tokenIn: Address;
      amountIn: bigint;
      slippageBps: bigint;
    }
  | {
      /**
       * King-only: set the current reign payout recipients.
       *
       * - ethRecipient receives dethroning ETH payouts
       * - claimRecipient receives CLAIM emission payouts
       */
      kind: 'mineCore.setCurrentReignRecipients';
      ethRecipient: Address;
      claimRecipient: Address;
    }
  | {
      /**
       * Configure king auto-lock behavior for this user.
       *
       * Mirrors MineCore.setKingAutoLockConfig(...).
       */
      kind: 'mineCore.setKingAutoLockConfig';
      enabled: boolean;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      minVeOut: bigint;
    }
  | {
      kind: 'royalties.claimShareholderEth';
      claimable: bigint;
    }
  | {
      /**
       * Claim shareholder ETH and lock via Furnace (mode=LOCK_FURNACE).
       *
       * The executor will:
       * - read current `claimableEth(msg.sender)` from ShareholderRoyalties
       * - quote `Furnace.quoteEnterWithEth` for that amount
       * - compute a slippage-adjusted `minVeOut`
       */
      kind: 'royalties.claimShareholderLock';
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      slippageBps: bigint;
    }
  | {
      /**
       * Configure ShareholderRoyalties auto-compound for this user.
       *
       * Mirrors ShareholderRoyalties.setAutoCompoundConfig(...).
       */
      kind: 'royalties.setAutoCompoundConfig';
      enabled: boolean;
      /** tokenId=0 means "use active lock" */
      tokenId: bigint;
      durationSeconds: bigint;
      minCadenceSeconds: bigint;
      minEthToCompound: bigint;
    }
  | {
      /** Delegated shareholder claim via ClaimAllHelper (ETH mode or Furnace-lock mode). */
      kind: 'claimAllHelper.claimShareholderForUser';
      user: Address;
      claimable: bigint;
      /** 0 = ETH, 1 = LOCK_FURNACE */
      mode: number;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      minVeOut: bigint;
    }
  | {
      /** Delegated king-bucket withdrawal via ClaimAllHelper (always withdraws to `user`). */
      kind: 'claimAllHelper.withdrawKingBalanceForUser';
      user: Address;
      amount: bigint;
    }
  | {
      /** Delegated bundle via ClaimAllHelper: claim shareholder + withdraw king bucket. */
      kind: 'claimAllHelper.claimAllFor';
      user: Address;
      claimable: bigint;
      /** 0 = ETH, 1 = LOCK_FURNACE */
      mode: number;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      minVeOut: bigint;
    }
  | {
      kind: 'mineCore.withdrawKingBalance';
      amount: bigint;
    }
  | {
      kind: 'mineCore.withdrawRefundBalance';
      amount: bigint;
      to: Address;
    }

  // ------------------------------------------------------------
  // Market actions (self-play only)
  // ------------------------------------------------------------
  | {
      /** Sell a veNFT lock back to the Furnace via MarketRouter, receiving liquid CLAIM. */
      kind: 'marketRouter.sellLockToFurnace';
      tokenId: bigint;
      slippageBps: bigint;
      /** Adds `deadlineSeconds` to the current chain timestamp when executing. */
      deadlineSeconds: bigint;
    }
  | {
      /** Sell a previously listed lock using its stored minClaimOut/expiry. */
      kind: 'marketRouter.sellListedLockToFurnace';
      tokenId: bigint;
      /** Adds `deadlineSeconds` to the current chain timestamp when executing. */
      deadlineSeconds: bigint;
    }
  | {
      /** List a veNFT lock for sale with a CLAIM-denominated minimum payout. */
      kind: 'marketRouter.listLock';
      tokenId: bigint;
      /** Minimum CLAIM acceptable for the lock. */
      minClaimOut: bigint;
      /** Adds `ttlSeconds` to the current chain timestamp when executing. */
      ttlSeconds: bigint;
    }
  | {
      /** Delist your own active listing (works even if trading is paused). */
      kind: 'marketRouter.delistLock';
      tokenId: bigint;
    }
  | {
      /** Permissionless: cancel an expired listing (works even if trading is paused). */
      kind: 'marketRouter.cancelExpiredListing';
      tokenId: bigint;
    }

  // ------------------------------------------------------------
  // MarketRouter: global offers (BonusTargetEscrow)
  // ------------------------------------------------------------
  | {
      /** Create a global buy offer that auto-fills into Furnace when a matching lock is sold. */
      kind: 'marketRouter.createBonusTargetEscrowWithTarget';
      /** Desired effective bonus bps at fill time (e.g. 2500 = 25%). */
      targetBonusBps: bigint;
      /** CLAIM budget escrowed in MarketRouter. */
      budgetClaim: bigint;
      /** Desired destination lock duration (seconds). Ignored when createAutoMax=true. */
      durationSeconds: bigint;
      /** If true, offer targets AutoMax locks (treated as MAX_LOCK_DURATION at fill time). */
      createAutoMax: boolean;
      /** Optional offer TTL (seconds). 0 uses protocol default. */
      escrowTtlSeconds: bigint;
      /** Optional destination lockId owned by buyer. 0 = unset. */
      destinationLockId: bigint;
      /** Slippage bps for the Furnace entry at fill time. */
      slippageBps: bigint;
    }
  | {
      /** Buyer-only: cancel an active offer and refund remaining budget. */
      kind: 'marketRouter.cancelBonusTargetEscrow';
      offerId: bigint;
    }
  | {
      /** Buyer-only: extend an active offer's expiry to (now + ttlSecondsFromNow). */
      kind: 'marketRouter.extendBonusTargetEscrowExpiry';
      offerId: bigint;
      ttlSecondsFromNow: bigint;
    }
  | {
      /** Permissionless: cancel an expired offer and refund remaining budget to the buyer (works even if trading is paused). */
      kind: 'marketRouter.cancelExpiredBonusTargetEscrow';
      offerId: bigint;
    }
  | {
      /** Permissionless: execute an active configured offer, locking remaining budget via Furnace for the buyer. */
      kind: 'marketRouter.executeAutoFurnace';
      offerId: bigint;
    }

  // ------------------------------------------------------------
  // Approvals (non-delegated)
  // ------------------------------------------------------------
  | {
      /** Generic ERC20 approval. */
      kind: 'erc20.approve';
      token: Address;
      spender: Address;
      amount: bigint;
    }
  | {
      /**
       * Ensure allowance is at least `minAllowance` (idempotent).
       *
       * If current allowance < minAllowance, set allowance to `approveAmount`.
       */
      kind: 'erc20.ensureAllowance';
      token: Address;
      spender: Address;
      minAllowance: bigint;
      approveAmount: bigint;
    }
  | {
      /** veNFT approve for a specific tokenId (ERC721 approve). */
      kind: 've.approve';
      spender: Address;
      tokenId: bigint;
    }
  | {
      /** veNFT operator approval (ERC721 setApprovalForAll). */
      kind: 've.setApprovalForAll';
      operator: Address;
      approved: boolean;
    }

  // ------------------------------------------------------------
  // Furnace: extend lock with bonus
  // ------------------------------------------------------------
  | {
      /** Extend a ve lock duration and receive a bonus CLAIM reward from the Furnace. */
      kind: 'furnace.extendWithBonus';
      tokenId: bigint;
      durationSeconds: bigint;
      minBonusOut: bigint;
    }
  | {
      /** Delegated: extend a user's ve lock duration with bonus via Furnace. */
      kind: 'furnace.extendWithBonusFor';
      user: Address;
      tokenId: bigint;
      durationSeconds: bigint;
      minBonusOut: bigint;
    }

  // ------------------------------------------------------------
  // veNFT self actions (non-delegated)
  // ------------------------------------------------------------
  | {
      /**
       * v1.0.0: Merge a shorter-duration lock into a longer-duration lock and earn an
       * extension-style bonus on the duration component. Replaces the legacy
       * `ve.mergeLocks` plan kind — raw `VeClaimNFT.mergeLocks` was removed; all merges
       * now route through `Furnace.mergeLocksWithBonus` so the bonus engine and reserve
       * accounting stay consistent with `enterWithClaim` / `extendWithBonus`.
       */
      kind: 'furnace.mergeLocksWithBonus';
      fromTokenId: bigint;
      intoTokenId: bigint;
      /** Slippage floor on the bonus CLAIM paid to the surviving lock; 0n disables. */
      minBonusOut: bigint;
    }
  | {
      kind: 've.unlock';
      tokenId: bigint;
    }
  | {
      kind: 've.setAutoMax';
      tokenId: bigint;
      enabled: boolean;
    }
  | {
      kind: 've.checkpointGlobalState';
    }
  | {
      kind: 've.checkpointTotalVe';
    }

  // ------------------------------------------------------------
  // Delegated account management (safe config + ve maintenance)
  // ------------------------------------------------------------
  | {
      /**
       * Delegated ve lock maintenance: merge one veNFT into another with an
       * extension-style bonus. v1.0.0 replaces `ve.mergeLocksForUser` — raw
       * `VeClaimNFT.mergeLocksForUser` was removed; the delegation gate now lives in
       * `Furnace.mergeLocksWithBonusFor`. The bonus CLAIM is always credited to `user`,
       * never to the caller / delegate.
       */
      kind: 'furnace.mergeLocksWithBonusFor';
      user: Address;
      fromTokenId: bigint;
      intoTokenId: bigint;
      /** Slippage floor on the bonus CLAIM paid to the surviving lock; 0n disables. */
      minBonusOut: bigint;
    }
  | {
      /** Delegated ve lock maintenance: unlock expired veNFT (CLAIM always returns to user). */
      kind: 've.unlockExpiredForUser';
      user: Address;
      tokenId: bigint;
    }
  | {
      /** Delegated MineCore King auto-lock config setter (safe, non-custodial). */
      kind: 'mineCore.setKingAutoLockConfigForUser';
      user: Address;
      enabled: boolean;
      targetTokenId: bigint;
      durationSeconds: bigint;
      createAutoMax: boolean;
      minVeOut: bigint;
    }
  | {
      /** Delegated ShareholderRoyalties auto-compound config setter (safe, non-custodial). */
      kind: 'royalties.setAutoCompoundConfigForUser';
      user: Address;
      enabled: boolean;
      tokenId: bigint;
      durationSeconds: bigint;
      minCadenceSeconds: bigint;
      minEthToCompound: bigint;
    }
  | {
      /** Delegated LP vault auto-compound config setter (safe, non-custodial). */
      kind: 'lpVault.setAutoCompoundConfigForUser';
      user: Address;
      enabled: boolean;
      tokenId: bigint;
      durationSeconds: bigint;
    };

export type AgentPlan = {
  chain: string;
  chainId: number;
  blockNumber: bigint;
  blockTimestamp: bigint;
  agent: Address;
  actions: AgentAction[];
};

export type AgentTxTelemetry = {
  /**
   * Which RPC route was used for sending the tx.
   *
   * - 'public': sent via the default rpcUrl
   * - 'private': sent via privateRpcUrl (MEV-sensitive allowlist)
   */
  route: 'public' | 'private';

  /**
   * Private RPC routing mode in effect.
   */
  privateRpcMode: 'off' | 'route' | 'only';

  /**
   * Managed nonce info (present when txManageNonces / txReplacement is enabled).
   */
  nonce?: bigint;
  /** Total broadcast attempts for the same nonce (1 = no replacement). */
  attempts?: number;
  /** All broadcast tx hashes for the nonce (first..last). */
  hashes?: Hash[];

  /**
   * Receipt-derived telemetry (present for mined txs).
   */
  blockNumber?: bigint;
  status?: string;
  gasUsed?: bigint;
  effectiveGasPrice?: bigint;
  feePaidWei?: bigint;
};

export type AgentActionResult = {
  action: AgentAction;
  simulated: boolean;
  /** Present when simulated (eth_call) returns a value. */
  result?: unknown;
  /** Extra structured details for logging (quotes, revert reasons, etc). */
  details?: Record<string, unknown>;
  /** Best-effort decoded error info when a viem execution error occurs. */
  errorInfo?: ClaimRushErrorInfo;

  /** Transaction telemetry for executed writes (and some tx errors). */
  tx?: AgentTxTelemetry;
  hash?: Hash;
  receiptBlockNumber?: bigint;
  error?: string;
};

export type LiveAgentResult = {
  ok: boolean;
  chain: string;
  chainId: number;
  agent: Address;
  /** The identity being managed (same as agent when self-playing). */
  user: Address;
  outdir?: string;
  lastSnapshot?: ClaimRushSnapshot;
};
