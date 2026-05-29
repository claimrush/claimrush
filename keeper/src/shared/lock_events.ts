/**
 * Shared helpers for keeper tasks that scan VeClaimNFT lock-lifecycle events.
 *
 * The two consumers (`automax_bonus.ts` and `checkpoint_before_expiry.ts`) keep
 * their own `LockRecord` shape and `scanLockEvents` orchestration — only the
 * pieces that were exact duplicates between the two are extracted here:
 *
 * - `EVT_AUTOMAX_SET` parseAbiItem constant.
 * - `resolveLockInfoForEvent` async helper that performs the canonical
 *   `getLockInfo(tokenId)` read at the event's block and returns a normalized
 *   `{ amount, lockEnd, autoMax }` triple (or `null` on RPC failure).
 *
 * Both consumers then decide whether to stash the `owner` field, how to
 * fall back on RPC failure, and how to thread the result into their own
 * lock cache.
 */

import type { Address, PublicClient } from 'viem';
import { parseAbiItem } from 'viem';

import { VE_CLAIM_NFT_ABI } from './abis.js';

/**
 * `VeClaimNFT.AutoMaxSet(user, tokenId, autoMax)` event ABI item.
 *
 * Emitted by `setAutoMax(tokenId, autoMax)` whenever a lock owner toggles the
 * autoMax flag post-creation. Without subscribing to this event the keeper's
 * lock cache only learns about autoMax from `LockCreated` and `LockMerged`
 * (which carry the autoMax flag in their payload), so a runtime toggle is
 * silently missed and the keeper either over-includes (toggle off) or
 * under-includes (toggle on) the lock in subsequent sweeps.
 */
export const EVT_AUTOMAX_SET = parseAbiItem(
  'event AutoMaxSet(address indexed user, uint256 indexed tokenId, bool autoMax)',
);

export interface ResolvedLockInfo {
  amount: bigint;
  lockEnd: bigint;
  autoMax: boolean;
}

/**
 * Fetches the canonical `(amount, lockEnd, autoMax)` triple from VeClaimNFT
 * at the block of the supplied event. Returns `null` if the RPC read fails;
 * callers should fall back to the event payload (or to the cached record)
 * when this happens.
 */
export async function resolveLockInfoForEvent({
  publicClient,
  veAddress,
  tokenId,
  blockNumber,
}: {
  publicClient: PublicClient;
  veAddress: Address;
  tokenId: bigint;
  blockNumber: bigint | null;
}): Promise<ResolvedLockInfo | null> {
  try {
    const info = (await publicClient.readContract({
      address: veAddress,
      abi: VE_CLAIM_NFT_ABI,
      functionName: 'getLockInfo',
      args: [tokenId],
      ...(blockNumber != null ? { blockNumber } : {}),
    })) as readonly [bigint, bigint, boolean, boolean];
    return {
      amount: info[0] ?? 0n,
      lockEnd: info[1] ?? 0n,
      autoMax: !!info[2],
    };
  } catch {
    return null;
  }
}
