import type { Account, PublicClient, WalletClient } from 'viem';

import type { AbiNetwork } from '../abis.js';
import type { ClaimRushContracts } from '../contracts.js';
import type { DeploymentManifest } from '../manifest.js';
import type { TxManager } from '../tx/txManager.js';

import { executeAgentAction } from './executor.js';
import type { AgentExecutionSecurity } from './actionSecurity.js';
import { expandPlanWithAutoApprovals } from './autoApprovals.js';
import type { AgentActionResult, AgentPlan } from './types.js';
import type { AutoApproveOptions } from './autoApprovals.js';

export type ExecuteAgentPlanParams = {
  plan: AgentPlan;

  publicClient: PublicClient;
  walletClient: WalletClient;
  /** Optional private tx sender for MEV-sensitive actions (takeovers + swaps). */
  privateWalletClient?: WalletClient;
  /** Routing mode for private tx sender. Default: 'route'. */
  privateRpcMode?: 'off' | 'route' | 'only';

  /** Optional tx manager (nonce management + optional replacement). */
  txManager?: TxManager;

  account: Account;

  manifest: DeploymentManifest;
  abiNetwork: AbiNetwork;
  contracts: ClaimRushContracts;

  /** Optional runtime security policy (allowlists, caps, validation) applied during execution. */
  security?: AgentExecutionSecurity;

  /** If false, only simulates each action (no tx). */
  execute: boolean;

  /** Max number of actions to process from the plan (default: all). */
  maxActions?: number;

  /** Stop execution on the first error (default: true). */
  stopOnError?: boolean;

  /** Optional: auto-insert required ERC20/veNFT approvals ahead of actions. */
  autoApprove?: AutoApproveOptions;

  onResult?: (result: AgentActionResult, idx: number) => void | Promise<void>;
};

export async function executeAgentPlan(p: ExecuteAgentPlanParams): Promise<AgentActionResult[]> {
  let plan = p.plan;

  if (p.execute && p.autoApprove?.enabled) {
    const expanded = await expandPlanWithAutoApprovals({
      plan,
      publicClient: p.publicClient,
      account: p.account,
      manifest: p.manifest,
      abiNetwork: p.abiNetwork,
      privateRpcMode: p.privateRpcMode,
      options: p.autoApprove,
    });
    plan = expanded.plan;
  }

  const max = p.maxActions ?? plan.actions.length;
  const stopOnError = p.stopOnError ?? true;

  const results: AgentActionResult[] = [];
  const actions = plan.actions.slice(0, Math.max(0, max));

  for (let i = 0; i < actions.length; i++) {
    const action = actions[i];

    const res = await executeAgentAction({
      publicClient: p.publicClient,
      walletClient: p.walletClient,
      privateWalletClient: p.privateWalletClient,
      privateRpcMode: p.privateRpcMode,
      txManager: p.txManager,
      account: p.account,
      manifest: p.manifest,
      abiNetwork: p.abiNetwork,
      contracts: p.contracts,
      execute: p.execute,
      action,
      security: p.security,
    });

    results.push(res);

    if (p.onResult) {
      await p.onResult(res, i);
    }

    if (stopOnError && res.error) {
      break;
    }
  }

  return results;
}
