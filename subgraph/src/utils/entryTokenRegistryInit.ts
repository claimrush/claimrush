import { Address, BigInt, dataSource } from "@graphprotocol/graph-ts";

import { EntryTokenRegistry as EntryTokenRegistryContract } from "../generated/templates/EntryTokenRegistry/EntryTokenRegistry";
import { EntryTokenRegistry } from "../generated/schema";

import { isZeroAddressBytes, loadOrCreateProtocol } from "./protocol";

function registryEntityId(registry: Address): string {
  return registry.toHexString();
}

/**
 * Initialize/refresh the EntryTokenRegistry entity using onchain reads.
 *
 * Why: Graph templates start indexing at creation block and will miss events
 * emitted earlier in the registry's lifetime (for example RouterConfigSet
 * emitted at registry deploy time). We therefore snapshot current config at
 * the moment the registry is wired into MineCore/Furnace.
 *
 * NOTE: Skipped on local networks to avoid BlockOutOfRangeError-style RPC
 * failures when indexing long Anvil histories.
 */
export function snapshotEntryTokenRegistry(registry: Address, ts: BigInt, blockNumber: BigInt): void {
  if (dataSource.network() == "local") {
    return;
  }

  const id = registryEntityId(registry);
  let r = EntryTokenRegistry.load(id);
  if (r == null) {
    r = new EntryTokenRegistry(id);
    r.address = registry;
  }

  const c = EntryTokenRegistryContract.bind(registry);

  const guardian = c.try_guardian();
  if (!guardian.reverted) {
    r.guardian = guardian.value;
  }

  const routerCfg = c.try_getRouterConfig();
  if (!routerCfg.reverted) {
    r.router = routerCfg.value.getRouter();
    r.factory = routerCfg.value.getFactory();
    r.wrappedNative = routerCfg.value.getWrappedNative();
    r.claimToken = routerCfg.value.getClaimToken();

    // Opportunistically fill Protocol.claimToken when it's still unknown.
    const protocol = loadOrCreateProtocol(blockNumber);
    if (isZeroAddressBytes(protocol.claimToken)) {
      protocol.claimToken = routerCfg.value.getClaimToken();
      protocol.save();
    }
  }

  const wethHop = c.try_getWethClaimHop();
  if (!wethHop.reverted) {
    r.wethClaimPoolStable = wethHop.value.getStable();
    r.wethClaimPool = wethHop.value.getPool();
  }

  r.updatedAt = ts;
  r.save();
}
