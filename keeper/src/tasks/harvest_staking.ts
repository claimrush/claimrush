import { LP_STAKING_VAULT_ABI } from '../shared/abis.js';
import { postAlert } from '../shared/alert.js';
import { sendContractTx } from '../shared/tx.js';
import { bumpRevertCount, initStatusState, nowUtcIso, updateStatusFile } from '../shared/state.js';
import { getContractAddress, requireNonZeroAddress } from '../shared/deployments.js';
import { parseChainIdStrict } from '../shared/chainId.js';
import { quoteMinClaimOutStaking } from './quotes.js';
import { MAX_LIVE_DEADLINE_SECS, type KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';

export async function runHarvestStaking({
  config,
  manifest,
  clients,
  log,
}: {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: (msg: string) => void;
}): Promise<unknown> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();
  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { harvestStaking: attemptAt },
    },
  });

  const vaultAddress = getContractAddress(manifest, 'LpStakingVault7D');
  requireNonZeroAddress(vaultAddress, 'LpStakingVault7D');

  const { publicClient, walletClient, account } = clients;

  const block = await publicClient.getBlock();
  if (block.timestamp === 0n) {
    throw new Error(
      'harvest_staking: block.timestamp is 0; RPC may be returning stale/invalid data',
    );
  }
  const clampedDeadlineSecs = BigInt(
    Math.min(Math.max(config.deadlineSecs, 30), config.liveRun ? MAX_LIVE_DEADLINE_SECS : 3600),
  );

  const q = await quoteMinClaimOutStaking({
    publicClient,
    vaultAddress,
    slippageBps: config.slippageBpsStaking,
    log,
  });

  if (!q.ok) {
    const err = `staking quote failed: ${q.error}`;
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastError: err,
        lastErrorByTask: { harvestStaking: err },
      },
    });

    await postAlert(config.alertWebhookUrl, {
      type: 'keeper_error',
      action: 'harvest_staking_quote',
      deployment: config.deployment,
      timestampUtc: nowUtcIso(),
      error: err,
    });

    if (config.allowUnsafeMinOut) {
      if (log)
        log(`CRITICAL: ${err} (allowUnsafeMinOut=1; using minClaimOut=0 — MEV sandwich risk)`);

      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_critical',
        action: 'harvest_staking_unsafe_min_out',
        deployment: config.deployment,
        timestampUtc: nowUtcIso(),
        error: `allowUnsafeMinOut active: submitting with minClaimOut=0. Original error: ${err}`,
      });
    } else {
      if (log) log(`${err} (skipping tx)`);
      return { skipped: true, reason: err };
    }
  }

  const minClaimOut = q.ok ? q.minClaimOut! : 0n;

  if (minClaimOut < config.harvestStakingMinReward) {
    if (log)
      log(
        `harvest-staking: dust skip (minClaimOut=${minClaimOut} < minReward=${config.harvestStakingMinReward})`,
      );
    return { skipped: true, reason: 'dust' };
  }

  let freshBlock: { timestamp: bigint };
  try {
    freshBlock = await publicClient.getBlock();
    if (freshBlock.timestamp === 0n) freshBlock = block;
  } catch {
    freshBlock = block;
  }
  const deadline = freshBlock.timestamp + clampedDeadlineSecs;

  if (log)
    log(`harvest staking: deadline=${deadline.toString()} minClaimOut=${minClaimOut.toString()}`);

  if (config.dryRun) {
    if (log) log('dry-run: not submitting LpStakingVault7D.harvestFeesToRewards');

    // Dry-run is a deliberate safety mode. Treat as a successful no-op for monitoring.
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { harvestStaking: successAt },
        lastError: null,
        lastErrorByTask: { harvestStaking: null },
      },
    });

    return { dryRun: true, deadline, minClaimOut };
  }

  let hash: `0x${string}` | null = null;
  try {
    const tx = await sendContractTx({
      config,
      publicClient,
      walletClient,
      account,
      address: vaultAddress,
      abi: LP_STAKING_VAULT_ABI,
      functionName: 'harvestFeesToRewards',
      args: [deadline, minClaimOut],
      minGasLimit: 500_000n,
      log,
      context: 'LpStakingVault7D.harvestFeesToRewards',
    });

    if (!tx.ok) {
      if (log) log(`tx skipped: ${tx.reason}`);

      // Skips are safety rails (paused, pending nonce guard, fee caps, etc).
      // Treat as a successful no-op so monitoring doesn't flag false failures.
      const skippedAt = nowUtcIso();
      updateStatusFile({
        statusPath: config.statusPath,
        init: statusInit,
        patch: {
          lastSuccessAtUtc: skippedAt,
          lastSuccessByTask: { harvestStaking: skippedAt },

          lastSkipAtUtc: skippedAt,
          lastSkipByTask: { harvestStaking: skippedAt },
          lastSkipReasonByTask: { harvestStaking: tx.reason },

          lastError: null,
          lastErrorByTask: { harvestStaking: null },
        },
      });

      return { skipped: true, reason: tx.reason, deadline, minClaimOut };
    }

    hash = tx.hash as `0x${string}`;
    const receipt = tx.receipt as any;

    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { harvestStaking: successAt },

        lastTxHash: hash,
        lastTxHashByTask: { harvestStaking: hash },

        lastError: null,
        lastErrorByTask: { harvestStaking: null },
      },
    });

    return { dryRun: false, hash, receipt };
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    const err = String(errObj?.shortMessage ?? errObj?.message ?? e);

    const patch: Record<string, unknown> = {
      lastError: err,
      lastErrorByTask: { harvestStaking: err },
    };
    if (hash) {
      patch.lastTxHash = hash;
      patch.lastTxHashByTask = { harvestStaking: hash };
    }

    const cur = updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch });

    const bumped = bumpRevertCount(cur, 'harvestStaking');
    updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch: bumped });

    await postAlert(config.alertWebhookUrl, {
      type: 'keeper_error',
      action: 'harvest_staking',
      deployment: config.deployment,
      timestampUtc: nowUtcIso(),
      error: err,
      txHash: hash,
    });

    throw e;
  }
}
