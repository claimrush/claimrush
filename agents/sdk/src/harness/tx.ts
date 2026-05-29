import type { Abi, Account, Address, Hash, PublicClient, WalletClient } from 'viem';

import type { TxManager } from '../tx/txManager.js';

/**
 * Thrown when a transaction is mined but the receipt status indicates a revert.
 *
 * viem's waitForTransactionReceipt does not throw on status=reverted, so the agent
 * needs to treat this as an error explicitly.
 */
export class TxRevertedError extends Error {
  override readonly name = 'TxRevertedError';
  readonly hash: Hash;
  readonly receipt: Awaited<ReturnType<PublicClient['waitForTransactionReceipt']>>;

  constructor(params: {
    hash: Hash;
    receipt: Awaited<ReturnType<PublicClient['waitForTransactionReceipt']>>;
  }) {
    super(`Transaction reverted (hash=${params.hash})`);
    this.hash = params.hash;
    this.receipt = params.receipt;
  }
}

export type WriteTxParams = {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;

  /**
   * Optional tx manager (nonce management + optional fee-bump replacement).
   *
   * When provided, the write path uses this instead of raw `walletClient.writeContract`.
   */
  txManager?: TxManager;
};

export async function simulateAndWrite(params: WriteTxParams): Promise<{
  hash: Hash;
  receipt: Awaited<ReturnType<PublicClient['waitForTransactionReceipt']>>;
  result?: unknown;
  meta?: { nonce: bigint; attempts: number; hashes: Hash[] };
}> {
  const sim = await params.publicClient.simulateContract({
    account: params.account,
    address: params.address,
    abi: params.abi,
    functionName: params.functionName as any,
    args: params.args as any,
    value: params.value,
  });

  let hash: Hash;
  let receipt: Awaited<ReturnType<PublicClient['waitForTransactionReceipt']>>;
  let meta: { nonce: bigint; attempts: number; hashes: Hash[] } | undefined;

  if (params.txManager) {
    const managed = await params.txManager.writeContract({
      walletClient: params.walletClient,
      request: sim.request,
    });
    hash = managed.hash;
    receipt = managed.receipt as any;
    meta = managed.meta;
  } else {
    hash = await params.walletClient.writeContract(sim.request);
    receipt = await params.publicClient.waitForTransactionReceipt({ hash });
  }

  // viem returns the receipt even when status is 'reverted'.
  // Treat this as an error so agents don't incorrectly assume success.
  const status = (receipt as any)?.status;
  if (status && status !== 'success') {
    throw new TxRevertedError({ hash, receipt });
  }

  return { hash, receipt, result: (sim as any).result, meta };
}
