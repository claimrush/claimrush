import { Address, BigInt } from "@graphprotocol/graph-ts";

import {
  FurnaceEntryTokenSafetySet,
  GuardianChanged,
  RouterConfigSet,
  TokenConfigSet,
  TokenEnabledChanged,
  WethClaimPoolSet,
} from "../generated/templates/EntryTokenRegistry/EntryTokenRegistry";

import { EntryTokenConfig, EntryTokenRegistry } from "../generated/schema";

import { loadOrCreateProtocol, isZeroAddressBytes, ZERO_ADDRESS } from "../utils/protocol";

function registryEntityId(registry: Address): string {
  return registry.toHexString();
}

function configEntityId(registry: Address, tokenIn: Address): string {
  return registry.toHexString() + "-" + tokenIn.toHexString();
}

function loadOrCreateRegistry(registry: Address): EntryTokenRegistry {
  const id = registryEntityId(registry);
  let r = EntryTokenRegistry.load(id);
  if (r == null) {
    r = new EntryTokenRegistry(id);
    r.address = registry;
  }
  return r as EntryTokenRegistry;
}

// Per-registry token-config entities grow linearly with the number of admitted tokens.
// Expected cardinality (~10-50 tokens) keeps the store footprint bounded.

function loadOrCreateTokenConfig(registry: Address, tokenIn: Address): EntryTokenConfig {
  const id = configEntityId(registry, tokenIn);
  let c = EntryTokenConfig.load(id);
  if (c == null) {
    c = new EntryTokenConfig(id);
    c.registry = registryEntityId(registry);
    c.tokenIn = tokenIn;

    // Defaults: these may be overwritten by TokenConfigSet.
    c.enabled = false;
    c.directToClaimEnabled = false;
    c.tokenClaimStable = false;
    c.tokenClaimPool = ZERO_ADDRESS;
    c.tokenWethStable = false;
    c.tokenWethPool = ZERO_ADDRESS;
    c.exactReceiptSafe = false;
    c.updatedAt = BigInt.fromI32(0);
  }
  return c as EntryTokenConfig;
}

export function handleGuardianChanged(event: GuardianChanged): void {
  const r = loadOrCreateRegistry(event.address);
  r.guardian = event.params.newGuardian;
  r.updatedAt = event.block.timestamp;
  r.save();
}

export function handleRouterConfigSet(event: RouterConfigSet): void {
  // Opportunistically fill claimToken from registry wiring if not already set.
  const protocol = loadOrCreateProtocol(event.block.number);
  if (isZeroAddressBytes(protocol.claimToken)) {
    protocol.claimToken = event.params.claimToken;
  }
  protocol.save();

  const r = loadOrCreateRegistry(event.address);
  r.router = event.params.router;
  r.factory = event.params.factory;
  r.wrappedNative = event.params.wrappedNative;
  r.claimToken = event.params.claimToken;
  r.updatedAt = event.block.timestamp;
  r.save();
}

export function handleWethClaimPoolSet(event: WethClaimPoolSet): void {
  const r = loadOrCreateRegistry(event.address);
  r.wethClaimPool = event.params.pool;
  r.wethClaimPoolStable = event.params.stable;
  r.updatedAt = event.block.timestamp;
  r.save();
}

export function handleTokenConfigSet(event: TokenConfigSet): void {
  // Persist the allowlisted token's routing configuration for transparency and future UI expansion.
  // Note: v1.0.0 UI does not currently surface this, but indexing keeps the data available.
  const r = loadOrCreateRegistry(event.address);
  r.updatedAt = event.block.timestamp;
  r.save();

  const c = loadOrCreateTokenConfig(event.address, event.params.tokenIn);
  c.enabled = event.params.enabled;
  c.directToClaimEnabled = event.params.directToClaimEnabled;
  c.tokenClaimStable = event.params.tokenClaimStable;
  c.tokenClaimPool = event.params.tokenClaimPool;
  c.tokenWethStable = event.params.tokenWethStable;
  c.tokenWethPool = event.params.tokenWethPool;
  c.updatedAt = event.block.timestamp;
  c.save();
}

export function handleFurnaceEntryTokenSafetySet(event: FurnaceEntryTokenSafetySet): void {
  const r = loadOrCreateRegistry(event.address);
  r.updatedAt = event.block.timestamp;
  r.save();

  const c = loadOrCreateTokenConfig(event.address, event.params.tokenIn);
  c.exactReceiptSafe = event.params.exactReceiptSafe;
  c.updatedAt = event.block.timestamp;
  c.save();
}

export function handleTokenEnabledChanged(event: TokenEnabledChanged): void {
  // This can occur without a full TokenConfigSet in edge-cases (or older history); ensure the entity exists.
  const c = loadOrCreateTokenConfig(event.address, event.params.tokenIn);
  c.enabled = event.params.enabled;
  c.updatedAt = event.block.timestamp;
  c.save();
}
