// Local devnet time-travel helpers (Anvil/Hardhat).
//
// `timeTravelTo` tries `evm_increaseTime`, `evm_setNextBlockTimestamp`, and
// `anvil_setNextBlockTimestamp` in order to cover common dev RPCs. Target
// timestamps at or before the current block resolve to a single mine, which
// is a no-op for time but advances the head block.

import type { PublicClient } from 'viem';

type RpcResult<T> =
  | { ok: true; value: T; method: string }
  | { ok: false; error: unknown; method: string };

async function tryRpc<T>(
  client: PublicClient,
  method: string,
  params: any[] = [],
): Promise<RpcResult<T>> {
  try {
    const value = (await client.request({ method: method as any, params: params as any })) as T;
    return { ok: true, value, method };
  } catch (error) {
    return { ok: false, error, method };
  }
}

async function mine(client: PublicClient): Promise<void> {
  // Most local devnets support evm_mine.
  const r1 = await tryRpc(client, 'evm_mine', []);
  if (r1.ok) return;
  // Anvil also supports anvil_mine.
  const r2 = await tryRpc(client, 'anvil_mine', []);
  if (r2.ok) return;
  throw new Error(
    `RPC does not support evm_mine/anvil_mine (last error: ${String((r2 as any).error ?? '')})`,
  );
}

/** Best-effort time travel to a target unix timestamp (seconds). Works on local devnets only. */
export async function timeTravelTo(
  client: PublicClient,
  targetTimestampSec: bigint,
): Promise<{ ok: boolean; method?: string }> {
  const head = await client.getBlock();
  const now = head.timestamp;
  if (targetTimestampSec <= now) {
    await mine(client);
    return { ok: true, method: 'mine-only' };
  }

  const delta = targetTimestampSec - now;

  const asRpcInt = (v: bigint): number | string => {
    if (v <= BigInt(Number.MAX_SAFE_INTEGER)) return Number(v);
    return v.toString();
  };

  // 1) Try evm_increaseTime(delta)
  {
    const r = await tryRpc(client, 'evm_increaseTime', [asRpcInt(delta)]);
    if (r.ok) {
      await mine(client);
      return { ok: true, method: r.method };
    }
  }

  // 2) Try evm_setNextBlockTimestamp(target)
  {
    const r = await tryRpc(client, 'evm_setNextBlockTimestamp', [asRpcInt(targetTimestampSec)]);
    if (r.ok) {
      await mine(client);
      return { ok: true, method: r.method };
    }
  }

  // 3) Try anvil_setNextBlockTimestamp(target)
  {
    const r = await tryRpc(client, 'anvil_setNextBlockTimestamp', [asRpcInt(targetTimestampSec)]);
    if (r.ok) {
      await mine(client);
      return { ok: true, method: r.method };
    }
  }

  return { ok: false };
}
