import path from 'node:path';
import type { Address } from 'viem';
import { createPublicClient, createWalletClient, getAddress, http, isAddress } from 'viem';

import { createClaimRushClients } from '../clients.js';
import { parseAndValidateOutboundUrlWithDns } from '../security/url.js';
import { redactJsonForLogging, redactUrlForLogging, safeErrorString } from '../security/redact.js';
import { createWriteStreamNoFollow, writeTextFileNoFollow } from '../security/fs.js';
import { getClaimRushContracts } from '../contracts.js';
import { getDelegationSession } from '../delegation/sessions.js';
import { assertManifestChainId, loadDeploymentManifest } from '../manifest.js';
import { startClaimRushEventStream, stringifyJson } from '../events.js';
import { getGameStateSnapshot, stringifySnapshot } from '../snapshot.js';
import { AchievementEngine } from '../achievements/index.js';
import { EventCursor } from './eventCursor.js';
import { BackoffController } from './backoff.js';
import { TxManager } from '../tx/txManager.js';
import { startAgentMonitor, type AgentMonitor } from './monitor.js';

import type { AbiNetwork } from '../abis.js';

import { DEFAULT_ANVIL_MNEMONIC, deriveActors } from '../harness/accounts.js';

import {
  buildActionPlan,
  type PolicyCallerContext,
  type PolicyConfig,
  type PolicyDelegationContext,
  type PolicyState,
} from './policy.js';
import { runStrategies, type AgentStrategyTrace } from './strategies.js';
import { summarizeAgentActionsForLog } from './planLog.js';
import { executeAgentAction } from './executor.js';
import type { AgentExecutionSecurity } from './actionSecurity.js';
import { expandPlanWithAutoApprovals } from './autoApprovals.js';
import type { AgentPlan, LiveAgentOptions, LiveAgentResult } from './types.js';

import {
  Signal,
  defaultOutdir,
  defaultStateDir,
  ensureDir,
  parseAutoApproveMode,
  parseBoolOrUndefined,
  parseEthOrZero,
  parseIntOrUndefined,
  parsePrivateRpcMode,
} from './runnerUtils.js';

import { DiscordNotifier } from './discord.js';

function clampFiniteInt(value: unknown, fallback: number, min: number, max: number): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.trunc(n);
  if (i < min) return min;
  if (i > max) return max;
  return i;
}

function optionalClampedInt(value: unknown, min: number, max: number): number | undefined {
  if (value === undefined || value === null) return undefined;
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) return undefined;
  const i = Math.trunc(n);
  if (i < min) return min;
  if (i > max) return max;
  return i;
}

export async function runLiveAgent(opts: LiveAgentOptions): Promise<LiveAgentResult> {
  const chain = opts.chain ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = opts.abiNetwork ?? ((process.env.ABI_NETWORK ?? 'base_sepolia') as AbiNetwork);

  const execute = opts.execute ?? false;
  const once = opts.once ?? false;
  const tickSecondsRaw = opts.tickSeconds ?? parseIntOrUndefined(process.env.TICK_SECONDS) ?? 10;
  const maxActionsPerTickRaw =
    opts.maxActionsPerTick ?? parseIntOrUndefined(process.env.MAX_ACTIONS_PER_TICK) ?? 1;

  const DEFAULT_MAX_PLANNED_ACTIONS = 5_000;
  const HARD_MAX_PLANNED_ACTIONS = 100_000;

  const maxPlannedActionsRaw =
    opts.maxPlannedActions ??
    parseIntOrUndefined(process.env.MAX_PLANNED_ACTIONS) ??
    DEFAULT_MAX_PLANNED_ACTIONS;

  // Cap values from config/env to avoid accidental OOM from extreme numbers.
  const maxPlannedActions = (() => {
    const n = Number(maxPlannedActionsRaw);
    if (!Number.isFinite(n)) return DEFAULT_MAX_PLANNED_ACTIONS;
    return Math.min(Math.max(0, Math.trunc(n)), HARD_MAX_PLANNED_ACTIONS);
  })();

  const tickSeconds = clampFiniteInt(tickSecondsRaw, 10, 0, 86_400);
  const maxActionsPerTick = clampFiniteInt(maxActionsPerTickRaw, 1, 0, maxPlannedActions);

  const useEvents =
    opts.useEvents ?? (process.env.USE_EVENTS ? process.env.USE_EVENTS === '1' : true);
  const eventPolling =
    opts.eventPolling ?? (process.env.EVENT_POLLING ? process.env.EVENT_POLLING === '1' : true);

  const subgraphUrl = opts.subgraphUrl ?? process.env.SUBGRAPH_URL;
  const eventBackfill =
    opts.eventBackfill ?? (process.env.EVENT_BACKFILL ? process.env.EVENT_BACKFILL === '1' : false);
  const eventBackfillLimit =
    optionalClampedInt(opts.eventBackfillLimit, 0, 5_000) ??
    optionalClampedInt(parseIntOrUndefined(process.env.EVENT_BACKFILL_LIMIT), 0, 5_000);

  const writeArtifacts =
    opts.writeArtifacts ??
    (process.env.WRITE_ARTIFACTS ? process.env.WRITE_ARTIFACTS === '1' : true);
  const outdir = writeArtifacts ? (opts.outdir ?? defaultOutdir()) : undefined;
  if (outdir) ensureDir(outdir);

  const writeTickRecords =
    writeArtifacts && outdir
      ? (opts.writeTickRecords ?? parseBoolOrUndefined(process.env.WRITE_TICK_RECORDS) ?? false)
      : false;

  const manifest = opts.manifest ?? loadDeploymentManifest({ chain });

  const validatedRpcUrl = (
    await parseAndValidateOutboundUrlWithDns(opts.rpcUrl, 'LiveAgentOptions.rpcUrl', {
      // Some providers embed basic auth in the URL.
      allowCredentials: true,
    })
  ).toString();

  const { publicClient } = createClaimRushClients({ rpcUrl: validatedRpcUrl });
  const chainId = await publicClient.getChainId();

  const allowChainIdMismatch =
    opts.allowChainIdMismatch ?? parseBoolOrUndefined(process.env.ALLOW_CHAIN_ID_MISMATCH) ?? false;

  assertManifestChainId(manifest, chainId, 'runLiveAgent', {
    allowMismatch: allowChainIdMismatch,
  });

  const actorIndexRaw = opts.actorIndex ?? parseIntOrUndefined(process.env.ACTOR_INDEX) ?? 0;
  const actorIndex = clampFiniteInt(actorIndexRaw, 0, 0, 10_000);
  const privateKeysCsv =
    opts.privateKeysCsv ??
    process.env.PRIVATE_KEYS ??
    (process.env.PRIVATE_KEY ? process.env.PRIVATE_KEY : undefined);

  const mnemonicRaw = opts.mnemonic ?? process.env.MNEMONIC ?? process.env.LOCAL_MNEMONIC;
  const mnemonic = (mnemonicRaw ?? DEFAULT_ANVIL_MNEMONIC).trim();

  const allowInsecureDefaultMnemonic =
    opts.allowInsecureDefaultMnemonic ??
    parseBoolOrUndefined(process.env.ALLOW_INSECURE_DEFAULT_MNEMONIC) ??
    false;

  const usingDefaultMnemonic = !privateKeysCsv && mnemonic === DEFAULT_ANVIL_MNEMONIC;

  if (chainId !== 31337 && usingDefaultMnemonic && !allowInsecureDefaultMnemonic) {
    throw new Error(
      `Refusing to run with DEFAULT_ANVIL_MNEMONIC on non-local chainId=${chainId}. ` +
        `Provide MNEMONIC or PRIVATE_KEYS. To bypass (not recommended), set ` +
        `allowInsecureDefaultMnemonic=true or ALLOW_INSECURE_DEFAULT_MNEMONIC=1.`,
    );
  }

  const actors = deriveActors({
    count: actorIndex + 1,
    mnemonic,
    privateKeysCsv,
  });

  if (!actors.length) {
    throw new Error('No accounts available (set MNEMONIC or PRIVATE_KEYS)');
  }

  const actor = actors[Math.min(actorIndex, actors.length - 1)];
  const agent = actor.account.address as Address;

  // Optional delegated mode: manage a separate identity via DelegationHub session.
  const actingForRaw = (opts.actingForUser ?? (process.env.ACTING_FOR_USER as any)) as
    | string
    | undefined;
  if (actingForRaw && actingForRaw.trim() && !isAddress(actingForRaw)) {
    throw new Error(`Invalid actingForUser address: ${actingForRaw}`);
  }
  const user = actingForRaw && actingForRaw.trim() ? (getAddress(actingForRaw) as Address) : agent;
  const delegated = user.toLowerCase() !== agent.toLowerCase();

  // Durable agent state dir (cursor, checkpoints, etc.).
  const stateDir =
    opts.stateDir ??
    process.env.AGENT_STATE_DIR ??
    defaultStateDir({ chain, chainId, agent, user });
  ensureDir(stateDir);

  // DelegationHub address (only needed in delegated mode).
  const delegationHub = delegated
    ? ((manifest.contracts as any).DelegationHub?.address as Address | undefined)
    : undefined;
  if (delegated && (!delegationHub || !isAddress(delegationHub))) {
    throw new Error('Delegated mode requires DelegationHub in the deployment manifest');
  }

  if (delegated) {
    console.log(`[agent] delegated mode: delegate=${agent} user=${user}`);
  }

  // Read-only contract clients.
  const contracts = await getClaimRushContracts({ publicClient, manifest, abiNetwork });

  // Wallet client for public mempool RPC (default write path).
  const walletClient = createWalletClient({
    transport: http(validatedRpcUrl, {
      fetchOptions: { redirect: 'error' },
    }),
    account: actor.account,
  });

  // Optional private RPC for MEV-sensitive sends (takeovers + swaps).
  const privateRpcUrlRaw = opts.privateRpcUrl ?? process.env.PRIVATE_RPC_URL;
  let privateRpcUrl: string | undefined;
  if (privateRpcUrlRaw && privateRpcUrlRaw.trim()) {
    privateRpcUrl = (
      await parseAndValidateOutboundUrlWithDns(privateRpcUrlRaw, 'LiveAgentOptions.privateRpcUrl', {
        allowCredentials: true,
      })
    ).toString();
  }
  const privateRpcMode = privateRpcUrl
    ? (opts.privateRpcMode ?? parsePrivateRpcMode(process.env.PRIVATE_RPC_MODE) ?? 'route')
    : ('off' as const);

  const allowPrivateRpcChainIdMismatch =
    opts.allowPrivateRpcChainIdMismatch ??
    parseBoolOrUndefined(process.env.ALLOW_PRIVATE_RPC_CHAIN_ID_MISMATCH) ??
    false;

  // Optional: private RPC public client for nonce discovery + chainId validation.
  const privateNonceClient =
    privateRpcUrl && privateRpcMode !== 'off'
      ? createPublicClient({
          transport: http(privateRpcUrl, { fetchOptions: { redirect: 'error' } }),
        })
      : undefined;

  if (privateNonceClient && privateRpcUrl && privateRpcMode !== 'off') {
    const privateChainId = await privateNonceClient.getChainId().catch(() => undefined);

    if (privateChainId === undefined) {
      const endpoint = redactUrlForLogging(privateRpcUrl);

      throw new Error(
        `Failed to read chainId from privateRpcUrl (endpoint=${endpoint}). Refusing to route txs via privateRpcUrl.`,
      );
    }

    if (privateChainId !== chainId) {
      const endpoint = redactUrlForLogging(privateRpcUrl);

      if (!allowPrivateRpcChainIdMismatch) {
        throw new Error(
          `privateRpcUrl chainId mismatch (rpcUrl chainId=${chainId}, privateRpc chainId=${privateChainId}, endpoint=${endpoint}). ` +
            `Refusing to continue. If this is intentional, set allowPrivateRpcChainIdMismatch=true or ALLOW_PRIVATE_RPC_CHAIN_ID_MISMATCH=1.`,
        );
      } else {
        console.log(
          `[agent] warn: privateRpcUrl chainId mismatch allowed (rpcUrl chainId=${chainId}, privateRpc chainId=${privateChainId}, endpoint=${endpoint})`,
        );
      }
    }
  }

  const privateWalletClient =
    privateRpcUrl && privateRpcMode !== 'off'
      ? createWalletClient({
          transport: http(privateRpcUrl, { fetchOptions: { redirect: 'error' } }),
          account: actor.account,
        })
      : undefined;

  // Optional: auto-insert approvals ahead of swap/takeover/market actions.
  let autoApproveEnabled =
    opts.autoApproveEnabled ?? parseBoolOrUndefined(process.env.AUTO_APPROVE_ENABLED) ?? false;
  const autoApproveMode =
    opts.autoApproveMode ?? parseAutoApproveMode(process.env.AUTO_APPROVE_MODE) ?? 'exact';
  const autoApproveIncludeNftApprovals =
    opts.autoApproveIncludeNftApprovals ??
    parseBoolOrUndefined(process.env.AUTO_APPROVE_NFT) ??
    true;

  if (autoApproveEnabled && privateRpcMode === 'only') {
    console.log(
      '[agent] AUTO_APPROVE_ENABLED ignored because PRIVATE_RPC_MODE=only blocks approval txs; pre-approve or use PRIVATE_RPC_MODE=route',
    );
    autoApproveEnabled = false;
  }

  // Optional: local HTTP monitor endpoint.
  const monitorEnabled =
    opts.monitorEnabled ?? parseBoolOrUndefined(process.env.AGENT_MONITOR_ENABLED) ?? false;
  const monitorPortRaw = opts.monitorPort ?? parseIntOrUndefined(process.env.AGENT_MONITOR_PORT);
  const monitorHost = opts.monitorHost ?? process.env.AGENT_MONITOR_HOST ?? '127.0.0.1';
  const monitorToken = opts.monitorToken ?? process.env.AGENT_MONITOR_TOKEN;
  const monitorMaxRecent =
    opts.monitorMaxRecent ?? parseIntOrUndefined(process.env.AGENT_MONITOR_MAX_RECENT) ?? 200;

  const shouldStartMonitor = monitorEnabled || monitorPortRaw !== undefined;
  const monitorPort = monitorPortRaw ?? (shouldStartMonitor ? 8787 : undefined);

  const monitor: AgentMonitor | undefined =
    shouldStartMonitor && monitorPort
      ? await startAgentMonitor({
          host: monitorHost,
          port: monitorPort,
          token: monitorToken,
          maxRecent: monitorMaxRecent,
          meta: {
            chain,
            chainId,
            agent,
            user,
            delegated,
            execute,
            outdir,
            stateDir,
            privateRpcMode,
          },
        })
      : undefined;

  if (monitor) {
    console.log(`[agent] monitor: ${monitor.url} (token=${monitorToken ? 'set' : 'none'})`);
  }

  // Optional Discord webhook notifications.
  const discordWebhookUrl = opts.discordWebhookUrl ?? process.env.DISCORD_WEBHOOK_URL;
  const discord = discordWebhookUrl
    ? new DiscordNotifier({ webhookUrl: discordWebhookUrl, chain })
    : undefined;

  // Optional: tx manager (managed nonces + optional fee-bump replacement)
  const replacementEnabled =
    parseBoolOrUndefined(process.env.TX_REPLACEMENT_ENABLED) ??
    parseBoolOrUndefined(process.env.TX_REPLACE_ENABLED) ??
    opts.txReplacementEnabled ??
    false;

  const manageNonces = replacementEnabled
    ? true
    : (opts.txManageNonces ?? parseBoolOrUndefined(process.env.TX_MANAGE_NONCES) ?? false);

  const txManager =
    execute && (manageNonces || replacementEnabled)
      ? new TxManager({
          publicClient,
          nonceClients: privateNonceClient ? [privateNonceClient] : undefined,
          address: actor.account.address,
          replacement: {
            enabled: replacementEnabled,
            timeoutMs:
              opts.txReplacementTimeoutMs ??
              parseIntOrUndefined(process.env.TX_REPLACEMENT_TIMEOUT_MS) ??
              45_000,
            pollIntervalMs:
              opts.txPollIntervalMs ??
              parseIntOrUndefined(process.env.TX_POLL_INTERVAL_MS) ??
              1_500,
            maxAttempts:
              opts.txReplacementMaxAttempts ??
              parseIntOrUndefined(process.env.TX_REPLACEMENT_MAX_ATTEMPTS) ??
              3,
            feeBumpBps:
              opts.txFeeBumpBps ?? parseIntOrUndefined(process.env.TX_FEE_BUMP_BPS) ?? 12_500,
          },
        })
      : undefined;

  // Optional: backoff / circuit-breaker for repeated failures (timeouts/reverts).
  const backoffEnabled =
    execute && (opts.backoffEnabled ?? parseBoolOrUndefined(process.env.BACKOFF_ENABLED) ?? true);
  const backoff = backoffEnabled
    ? new BackoffController({
        enabled: true,
        baseCooldownMs:
          opts.backoffBaseCooldownMs ?? parseIntOrUndefined(process.env.BACKOFF_BASE_MS) ?? 15_000,
        maxCooldownMs:
          opts.backoffMaxCooldownMs ??
          parseIntOrUndefined(process.env.BACKOFF_MAX_MS) ??
          5 * 60_000,
        multiplier:
          opts.backoffMultiplier ?? parseIntOrUndefined(process.env.BACKOFF_MULTIPLIER) ?? 2,
        maxConsecutiveTimeouts:
          opts.backoffMaxConsecutiveTimeouts ??
          parseIntOrUndefined(process.env.BACKOFF_MAX_TIMEOUTS) ??
          1,
        maxConsecutiveErrors:
          opts.backoffMaxConsecutiveErrors ??
          parseIntOrUndefined(process.env.BACKOFF_MAX_ERRORS) ??
          3,
        resetAfterMs:
          opts.backoffResetAfterMs ??
          parseIntOrUndefined(process.env.BACKOFF_RESET_AFTER_MS) ??
          2 * 60_000,
      })
    : undefined;
  // Strategy defaults: safe by default
  const enableFurnaceEntry = opts.enableFurnaceEntry ?? process.env.ENABLE_FURNACE_ENTRY === '1';
  const enableTakeovers = opts.enableTakeovers ?? process.env.ENABLE_TAKEOVERS === '1';
  const enableRoyaltiesClaim =
    opts.enableRoyaltiesClaim ??
    (process.env.ENABLE_ROYALTIES_CLAIM ? process.env.ENABLE_ROYALTIES_CLAIM === '1' : true);
  const enableWithdrawals =
    opts.enableWithdrawals ??
    (process.env.ENABLE_WITHDRAWALS ? process.env.ENABLE_WITHDRAWALS === '1' : true);

  const furnaceEthIn = parseEthOrZero(opts.furnaceEthIn ?? process.env.FURNACE_ETH_IN);
  const lockDurationDays = clampFiniteInt(
    opts.lockDurationDays ?? parseIntOrUndefined(process.env.LOCK_DURATION_DAYS) ?? 30,
    30,
    0,
    3650,
  );
  const lockDurationSeconds = BigInt(lockDurationDays) * 24n * 60n * 60n;
  const targetTokenId = opts.targetTokenId ?? 0n;
  const createAutoMax = opts.createAutoMax ?? process.env.CREATE_AUTO_MAX === '1';
  const slippageBps = BigInt(
    clampFiniteInt(
      opts.slippageBps ?? parseIntOrUndefined(process.env.SLIPPAGE_BPS) ?? 50,
      50,
      0,
      10_000,
    ),
  );

  const maxTakeoverEth = parseEthOrZero(opts.maxTakeoverEth ?? process.env.MAX_TAKEOVER_ETH);
  const takeoverCooldownSeconds = clampFiniteInt(
    opts.takeoverCooldownSeconds ??
      parseIntOrUndefined(process.env.TAKEOVER_COOLDOWN_SECONDS) ??
      60,
    60,
    0,
    86_400,
  );

  const minRoyaltiesEthToClaim = parseEthOrZero(
    opts.minRoyaltiesEthToClaim ?? process.env.MIN_ROYALTIES_ETH,
  );
  const minKingEthToWithdraw = parseEthOrZero(
    opts.minKingEthToWithdraw ?? process.env.MIN_KING_ETH,
  );
  const minRefundEthToWithdraw = parseEthOrZero(
    opts.minRefundEthToWithdraw ?? process.env.MIN_REFUND_ETH,
  );

  // Delegated safe maintenance (optional)
  const enableSafeMaintenance =
    opts.enableSafeMaintenance ?? process.env.ENABLE_SAFE_MAINTENANCE === '1';
  const veExtendIfRemainingDays = clampFiniteInt(
    opts.veExtendIfRemainingDays ??
      parseIntOrUndefined(process.env.VE_EXTEND_IF_REMAINING_DAYS) ??
      7,
    7,
    0,
    3650,
  );
  const veExtendByDays = clampFiniteInt(
    opts.veExtendByDays ?? parseIntOrUndefined(process.env.VE_EXTEND_BY_DAYS) ?? 30,
    30,
    0,
    3650,
  );
  const veExtendIfRemainingSeconds = BigInt(veExtendIfRemainingDays) * 24n * 60n * 60n;
  const veExtendBySeconds = BigInt(veExtendByDays) * 24n * 60n * 60n;

  const policyConfig: PolicyConfig = {
    agent,
    enableFurnaceEntry,
    enableTakeovers,
    enableRoyaltiesClaim,
    enableWithdrawals,
    furnaceEthIn,
    lockDurationSeconds,
    targetTokenId,
    createAutoMax,
    slippageBps,
    maxTakeoverEth,
    takeoverCooldownSeconds,
    minRoyaltiesEthToClaim,
    minKingEthToWithdraw,
    minRefundEthToWithdraw,

    enableSafeMaintenance,
    veExtendIfRemainingSeconds,
    veExtendBySeconds,
    kingAutoLockDesired: opts.kingAutoLockDesired,
    royaltiesAutoCompoundDesired: opts.royaltiesAutoCompoundDesired,
    lpAutoCompoundDesired: opts.lpAutoCompoundDesired,
  };

  const defaultMaxCallValueWei =
    policyConfig.furnaceEthIn > policyConfig.maxTakeoverEth
      ? policyConfig.furnaceEthIn
      : policyConfig.maxTakeoverEth;

  const execSecurity: AgentExecutionSecurity = {
    ...(opts.executionSecurity ?? {}),
    // Block the highest-risk configuration action by default (opt-in via executionSecurity).
    deniedActionKinds: opts.executionSecurity?.deniedActionKinds ?? [
      'mineCore.setCurrentReignRecipients',
    ],
    // Prevent strategies/plugins from silently widening slippage beyond configured tolerance.
    maxSlippageBps: (opts.executionSecurity?.maxSlippageBps ?? policyConfig.slippageBps) as bigint,
    // Prevent strategies/plugins from sending more native value than configured caps allow.
    maxCallValueWei: (opts.executionSecurity?.maxCallValueWei ?? defaultMaxCallValueWei) as bigint,
    // In delegated mode, scope execution to the configured target user (unless explicitly disabled).
    delegatedUserAllowlist:
      delegated && !opts.executionSecurity?.allowAnyDelegatedUser
        ? (opts.executionSecurity?.delegatedUserAllowlist ?? [user])
        : opts.executionSecurity?.delegatedUserAllowlist,
  };

  const state: PolicyState = {};

  // Artifact writers
  const decisionsFp = outdir ? path.join(outdir, 'decisions.jsonl') : undefined;
  const txsFp = outdir ? path.join(outdir, 'txs.jsonl') : undefined;
  const eventsFp = outdir ? path.join(outdir, 'events.jsonl') : undefined;
  const achievementsFp = outdir ? path.join(outdir, 'achievements.jsonl') : undefined;
  const latestSnapshotFp = outdir ? path.join(outdir, 'snapshot.latest.json') : undefined;
  const sessionFp = outdir ? path.join(outdir, 'session.json') : undefined;
  const ticksFp = outdir && writeTickRecords ? path.join(outdir, 'ticks.jsonl') : undefined;

  // Session metadata (useful for deterministic replay)
  if (sessionFp) {
    writeTextFileNoFollow(
      sessionFp,
      stringifyJson({
        version: 'v1',
        ts: Date.now(),
        chain,
        chainId,
        agent,
        user,
        delegated,
        execute,
        outdir,
        stateDir,
        privateRpcMode,
        autoApproveEnabled,
        autoApproveMode,
        autoApproveIncludeNftApprovals,
        writeTickRecords,
        planning:
          opts.strategies && opts.strategies.length
            ? {
                mode: 'strategies',
                strategies: opts.strategies.map((s) => ({ id: s.id, priority: s.priority ?? 0 })),
              }
            : { mode: 'policy' },
        policyConfig,
        executionSecurity: execSecurity,
      }) + '\n',
      { encoding: 'utf8', mode: 0o600 },
    );
  }

  const decisionsWs = decisionsFp
    ? createWriteStreamNoFollow(decisionsFp, { append: true, mode: 0o600 })
    : undefined;
  const txsWs = txsFp ? createWriteStreamNoFollow(txsFp, { append: true, mode: 0o600 }) : undefined;
  const eventsWs = eventsFp
    ? createWriteStreamNoFollow(eventsFp, { append: true, mode: 0o600 })
    : undefined;
  const achievementsWs = achievementsFp
    ? createWriteStreamNoFollow(achievementsFp, { append: true, mode: 0o600 })
    : undefined;
  const ticksWs = ticksFp
    ? createWriteStreamNoFollow(ticksFp, { append: true, mode: 0o600 })
    : undefined;

  const achievements = achievementsWs
    ? new AchievementEngine({
        chain,
        chainId,
        agent,
        user,

        subgraphUrl,
        subgraphLagThresholdBlocks: optionalClampedInt(
          parseIntOrUndefined(process.env.SUBGRAPH_LAG_THRESHOLD_BLOCKS),
          0,
          1_000_000,
        ),
        subgraphCheckIntervalMs: optionalClampedInt(
          parseIntOrUndefined(process.env.SUBGRAPH_CHECK_INTERVAL_MS),
          1_000,
          3_600_000,
        ),

        rpcLagThresholdSeconds: optionalClampedInt(
          parseIntOrUndefined(process.env.RPC_LAG_THRESHOLD_SECONDS),
          0,
          1_000_000,
        ),
        rpcLagRecentBlockChangeWindowSeconds: optionalClampedInt(
          parseIntOrUndefined(process.env.RPC_LAG_RECENT_WINDOW_SECONDS),
          1,
          1_000_000,
        ),

        achievementsBaseUrl: opts.achievementsBaseUrl ?? process.env.ACHIEVEMENTS_BASE_URL,
        achievementsPollIntervalMs:
          optionalClampedInt(opts.achievementsPollIntervalMs, 1_000, 3_600_000) ??
          optionalClampedInt(
            parseIntOrUndefined(process.env.ACHIEVEMENTS_POLL_MS),
            1_000,
            3_600_000,
          ),
        achievementsForceRefreshCooldownMs:
          optionalClampedInt(opts.achievementsForceRefreshCooldownMs, 1_000, 86_400_000) ??
          optionalClampedInt(
            parseIntOrUndefined(process.env.ACHIEVEMENTS_REFRESH_COOLDOWN_MS),
            1_000,
            86_400_000,
          ),
        achievementsFetchTimeoutMs:
          optionalClampedInt(opts.achievementsFetchTimeoutMs, 1_000, 300_000) ??
          optionalClampedInt(
            parseIntOrUndefined(process.env.ACHIEVEMENTS_TIMEOUT_MS),
            1_000,
            300_000,
          ),

        emitActionUtility: process.env.EMIT_ACTION_UTILITY === '1',

        write: (a) => {
          achievementsWs.write(stringifyJson(a) + '\n');
          monitor?.onAchievement(a);
        },
      })
    : undefined;

  const wake = new Signal();
  let stopped = false;

  const stop = () => {
    stopped = true;
    wake.trigger();
  };

  process.on('SIGINT', () => {
    stop();
  });

  let streamStop: (() => void) | undefined;
  if (useEvents) {
    const rewindBlocksN = clampFiniteInt(
      opts.eventCursorRewindBlocks ??
        parseIntOrUndefined(process.env.EVENT_CURSOR_REWIND_BLOCKS) ??
        20,
      20,
      0,
      100_000,
    );
    const rewindBlocks = BigInt(rewindBlocksN);

    const maxRecentKeys = clampFiniteInt(
      opts.eventCursorMaxRecentKeys ??
        parseIntOrUndefined(process.env.EVENT_CURSOR_MAX_KEYS) ??
        5_000,
      5_000,
      0,
      100_000,
    );

    const cursor = EventCursor.load({
      filePath: path.join(stateDir, 'event-cursor.json'),
      chainId,
      rewindBlocks,
      maxRecentKeys,
    });

    const validation = await cursor.validateAgainstChain(publicClient);
    if (!validation.ok) {
      const msg = {
        level: 'warn',
        message: 'event cursor reorg detected; rewound cursor',
        previousLastProcessedBlock: validation.rewoundFrom?.toString() ?? '0',
      };
      if (eventsWs) eventsWs.write(stringifyJson(msg) + '\n');
      else console.warn(`[agent] ${msg.message} (rewoundFrom=${msg.previousLastProcessedBlock})`);
    }

    monitor?.setEventCursorSnapshot(cursor.snapshot());

    const handle = await startClaimRushEventStream({
      publicClient,
      manifest,
      abiNetwork,
      subgraphUrl,
      backfillFromSubgraph: eventBackfill,
      backfillLimit: eventBackfillLimit,
      poll: eventPolling,
      // Tight defaults: only what changes decisions
      contracts: ['MineCore', 'Furnace', 'ShareholderRoyalties'],
      events: [
        'Takeover',
        'KingWithdrawal',
        'FurnaceEnter',
        'ShareholderClaim',
        'ShareholderAutoCompoundExecuted',
      ],
      fromBlock: cursor.getStartBlock(),
      onEvent: async (ev) => {
        if (!cursor.shouldProcess(ev)) return;
        if (eventsWs) eventsWs.write(stringifyJson(ev) + '\n');
        if (achievements) achievements.onEvent(ev);
        monitor?.onEvent(ev);
        await cursor.recordProcessedEvent(ev, publicClient);
        monitor?.setEventCursorSnapshot(cursor.snapshot());
        wake.trigger();
      },
      onError: (err) => {
        if (eventsWs)
          eventsWs.write(stringifyJson({ level: 'error', error: safeErrorString(err) }) + '\n');
      },
    });
    streamStop = () => handle.stop();
  }

  let lastSnapshot: any = undefined;

  async function writeLatestSnapshot(snap: any): Promise<void> {
    if (!latestSnapshotFp) return;
    writeTextFileNoFollow(latestSnapshotFp, stringifySnapshot(snap, { pretty: true }) + '\n', {
      encoding: 'utf8',
      mode: 0o600,
    });
  }

  function capPlannedActions(actions: AgentPlan['actions'], stage: string): AgentPlan['actions'] {
    if (actions.length <= maxPlannedActions) return actions;
    console.warn(
      `[agent] ${stage}: truncating planned actions ${actions.length} -> ${maxPlannedActions} (MAX_PLANNED_ACTIONS)`,
    );
    return actions.slice(0, maxPlannedActions);
  }

  function logPlan(plan: AgentPlan, strategyTraces?: AgentStrategyTrace[]): void {
    const summary = {
      ts: Date.now(),
      chain,
      chainId,
      agent,
      user,
      blockNumber: plan.blockNumber.toString(),
      delegated: delegated ? '1' : '0',
      execute: execute ? '1' : '0',
      strategyTraces: strategyTraces
        ? strategyTraces.map((t) => ({
            id: t.id,
            priority: t.priority,
            ok: t.ok ? '1' : '0',
            durationMs: t.durationMs,
            actionCount: t.actionCount,
            stop: t.stop ? '1' : '0',
            error: t.error,
          }))
        : undefined,
      actions: summarizeAgentActionsForLog(plan.actions),
    };

    if (decisionsWs) decisionsWs.write(stringifyJson(summary) + '\n');

    // Console-friendly one-liner
    const first = summary.actions[0];
    if (!first) {
      console.log(`[agent] block=${summary.blockNumber} actions=0 execute=${execute ? '1' : '0'}`);
      return;
    }
    console.log(
      `[agent] block=${summary.blockNumber} actions=${summary.actions.length} next=${first.kind} execute=${execute ? '1' : '0'}`,
    );
  }

  if (discord) {
    await discord.notifyStarted({
      agent,
      user,
      delegated,
      execute,
      chainId,
      enableTakeovers,
      maxTakeoverEth,
    });
  }

  try {
    while (!stopped) {
      const snap = await getGameStateSnapshot({
        publicClient,
        manifest,
        abiNetwork,
        user,
      });

      lastSnapshot = snap;

      monitor?.onSnapshot({
        blockNumber: snap.meta.blockNumber,
        blockTimestamp: snap.meta.blockTimestamp,
      });
      await writeLatestSnapshot(snap);

      // In delegated mode we need to know caller balances + active session perms.
      let caller: PolicyCallerContext | undefined;
      let delegation: PolicyDelegationContext | undefined;

      if (delegated) {
        const callerEthBalance = await publicClient.getBalance({ address: agent });
        const mineCoreKingEthBalance = (await (contracts as any).MineCore.read.kingEthBalance([
          agent,
        ])) as bigint;
        const mineCoreRefundEthBalance = (await (contracts as any).MineCore.read.refundEthBalance([
          agent,
        ])) as bigint;

        caller = {
          address: agent,
          ethBalance: callerEthBalance,
          mineCoreKingEthBalance,
          mineCoreRefundEthBalance,
        };

        const session = await getDelegationSession({
          publicClient,
          delegationHub: delegationHub as Address,
          user,
          delegate: agent,
          abiNetwork,
        });

        delegation = {
          user,
          delegate: agent,
          perms: session.perms,
          expiry: session.expiry,
        };
      }

      if (achievements) {
        await achievements.onTick({
          snapshot: snap,
          config: {
            enableTakeovers,
            enableFurnaceEntry,
          },
          delegation: delegation
            ? {
                expiry: delegation.expiry,
                perms: delegation.perms,
              }
            : undefined,
        });
      }

      const nowMs = Date.now();

      if (ticksWs) {
        ticksWs.write(
          stringifyJson({
            version: 'v1',
            ts: nowMs,
            nowMs,
            chain,
            chainId,
            agent,
            user,
            delegated,
            execute,
            policyState: state,
            caller,
            delegation,
            snapshot: snap,
          }) + '\n',
        );
      }

      let strategyTraces: AgentStrategyTrace[] | undefined;
      let actions: AgentPlan['actions'];
      if (opts.strategies && opts.strategies.length) {
        const out = await runStrategies({
          strategies: opts.strategies,
          ctx: {
            chain,
            chainId,
            agent,
            user,
            snapshot: snap,
            config: policyConfig,
            state,
            nowMs,
            caller,
            delegation,
          },
          maxActions: maxPlannedActions,
        });

        actions = capPlannedActions(out.actions, 'strategies');
        strategyTraces = out.traces;
      } else {
        actions = capPlannedActions(
          buildActionPlan({
            snapshot: snap,
            config: policyConfig,
            state,
            nowMs,
            caller,
            delegation,
          }),
          'policy',
        );
      }
      let plan: AgentPlan = {
        chain,
        chainId,
        agent,
        blockNumber: snap.meta.blockNumber,
        blockTimestamp: snap.meta.blockTimestamp,
        actions,
      };

      if (execute && autoApproveEnabled && plan.actions.length) {
        const expanded = await expandPlanWithAutoApprovals({
          plan,
          publicClient,
          account: actor.account,
          manifest,
          abiNetwork,
          privateRpcMode,
          options: {
            enabled: true,
            mode: autoApproveMode,
            includeNftApprovals: autoApproveIncludeNftApprovals,
          },
        });

        plan = expanded.plan;
        actions = capPlannedActions(plan.actions, 'auto-approve');
        plan = { ...plan, actions };

        if (expanded.notes.length) {
          console.log(`[agent] auto-approve: ${expanded.notes.join('; ')}`);
        }
      }

      if (achievements) {
        achievements.onPlan(plan);
      }

      monitor?.onPlan(plan);

      if (strategyTraces && strategyTraces.length) {
        monitor?.onStrategies({ blockNumber: plan.blockNumber, traces: strategyTraces });
      }

      logPlan(plan, strategyTraces);

      const backoffTransition = backoff?.maybeClear();
      if (backoffTransition && achievements) {
        achievements.onBackoff(backoffTransition);
      }
      if (backoffTransition) {
        monitor?.onBackoff(backoffTransition);
      }

      const toRun = actions.slice(0, Math.max(0, maxActionsPerTick));
      for (const action of toRun) {
        const nowMs = Date.now();
        const backoffActive = backoff ? backoff.isActive(nowMs) : false;
        const effectiveExecute = execute && !backoffActive;

        const res0 = await executeAgentAction({
          publicClient,
          walletClient,
          privateWalletClient,
          privateRpcMode,
          txManager,
          account: actor.account,
          manifest,
          abiNetwork,
          contracts,
          execute: effectiveExecute,
          action,
          security: execSecurity,
        });

        const res =
          execute && backoffActive && !effectiveExecute
            ? {
                ...res0,
                details: {
                  ...(res0.details ?? {}),
                  backoff: {
                    active: true,
                    remainingMs: backoff?.remainingMs(nowMs),
                    cooldownUntilMs: backoff?.snapshot().cooldownUntilMs,
                  },
                },
              }
            : res0;

        const backoffAfter = backoff?.onActionResult(res);
        if (backoffAfter && achievements) {
          achievements.onBackoff(backoffAfter);
        }
        if (backoffAfter) {
          monitor?.onBackoff(backoffAfter);
        }

        if (txsWs) {
          txsWs.write(
            stringifyJson({
              ts: Date.now(),
              chain,
              chainId,
              agent,
              user,
              action: res.action,
              simulated: res.simulated,
              hash: res.hash,
              receiptBlockNumber: res.receiptBlockNumber
                ? res.receiptBlockNumber.toString()
                : undefined,
              tx: res.tx,
              errorInfo: res.errorInfo
                ? { ...res.errorInfo, message: safeErrorString(res.errorInfo.message) }
                : undefined,

              details: res.details ? (redactJsonForLogging(res.details) as any) : undefined,
              error: res.error ? safeErrorString(res.error) : undefined,
            }) + '\n',
          );
        }

        monitor?.onTxResult(res);

        if (discord) {
          await discord.notifyActionResult(res);
        }

        if (achievements) {
          achievements.onActionResult(res);
        }

        if (
          !res.error &&
          !res.simulated &&
          (action.kind === 'mineCore.takeover' ||
            action.kind === 'mineCore.takeoverFor' ||
            action.kind === 'mineCore.takeoverWithToken')
        ) {
          state.lastTakeoverAtMs = Date.now();
        }

        // If we executed something, re-evaluate quickly.
        if (!res.error && !res.simulated) {
          wake.trigger();
        }

        // If we tripped the circuit breaker, stop after this action.
        if (backoffAfter?.kind === 'entered') {
          break;
        }
      }
      if (once) break;

      await wake.wait(Math.max(1, tickSeconds) * 1000);
    }
  } catch (err) {
    if (discord) await discord.notifyError(err);
    throw err;
  } finally {
    if (discord) await discord.notifyStopped();
    if (streamStop) streamStop();
    if (monitor) await monitor.close();
    if (decisionsWs) decisionsWs.end();
    if (txsWs) txsWs.end();
    if (eventsWs) eventsWs.end();
    if (achievementsWs) achievementsWs.end();
    if (ticksWs) ticksWs.end();
  }

  return {
    ok: true,
    chain,
    chainId,
    agent,
    user,
    outdir,
    lastSnapshot,
  };
}
