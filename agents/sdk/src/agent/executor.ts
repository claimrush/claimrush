import type { Account, PublicClient, WalletClient } from 'viem';

import type { AbiNetwork } from '../abis.js';
import type { ClaimRushContracts } from '../contracts.js';
import type { DeploymentManifest } from '../manifest.js';
import type { TxManager } from '../tx/txManager.js';

import type { AgentAction, AgentActionResult } from './types.js';
import type { AgentExecutionSecurity } from './actionSecurity.js';

import { executeAgentActionImpl } from './executorImpl.js';

export type ExecuteAgentActionParams = {
  /** Optional tx manager (nonce + replacement). */
  txManager?: TxManager;

  publicClient: PublicClient;
  walletClient: WalletClient;

  /** Optional private tx sender for MEV-sensitive actions (takeovers + swaps). */
  privateWalletClient?: WalletClient;
  /** Routing mode for private tx sender. Default: 'route'. */
  privateRpcMode?: 'off' | 'route' | 'only';

  account: Account;

  manifest: DeploymentManifest;
  abiNetwork: AbiNetwork;
  contracts: ClaimRushContracts;

  execute: boolean;
  action: AgentAction;

  /** Optional runtime security policy (allowlists, input validation, value caps). */
  security?: AgentExecutionSecurity;
};

export async function executeAgentAction(p: ExecuteAgentActionParams): Promise<AgentActionResult> {
  return await executeAgentActionImpl(p);
}
