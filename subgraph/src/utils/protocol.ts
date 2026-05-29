import { Address, BigInt, Bytes, dataSource } from '@graphprotocol/graph-ts';

import { AprSnapshot, Protocol, TokenPricingSnapshot } from '../generated/schema';

export const PROTOCOL_ID = '1';
export const PROTOCOL_VERSION = 'v1.0.0';

// NOTE: The same mappings run on multiple networks (base mainnet, base sepolia, local dev).
// Keep the chainId derived from the manifest network name so downstream consumers can reason about it.
export function chainIdFromNetwork(): i32 {
  const net = dataSource.network();

  if (net == 'base') return 8453; // Base mainnet
  if (net == 'base-sepolia') return 84532; // Base Sepolia
  if (net == 'local') return 31337; // Anvil/Hardhat default

  // Unknown network: keep deterministic, but don't lie.
  return 0;
}

export const ZERO_ADDRESS_STRING = '0x0000000000000000000000000000000000000000';
export const ZERO_ADDRESS = Address.fromString(ZERO_ADDRESS_STRING);

const ZERO = BigInt.fromI32(0);

export function isZeroAddressBytes(b: Bytes): bool {
  return b.toHexString() == ZERO_ADDRESS.toHexString();
}

// Ensure singleton info-surface entities exist (even if all fields are null early).
function ensureInfoSurfaces(): void {
  if (TokenPricingSnapshot.load(PROTOCOL_ID) == null) {
    const s = new TokenPricingSnapshot(PROTOCOL_ID);
    s.save();
  }

  if (AprSnapshot.load(PROTOCOL_ID) == null) {
    const a = new AprSnapshot(PROTOCOL_ID);
    a.save();
  }
}

export function loadOrCreateProtocol(deployedAtBlock: BigInt | null): Protocol {
  let p = Protocol.load(PROTOCOL_ID);
  let created = false;
  if (p == null) {
    created = true;
    p = new Protocol(PROTOCOL_ID);

    p.chainId = chainIdFromNetwork();
    p.version = PROTOCOL_VERSION;
    // Avoid nullable union assignment under stricter AssemblyScript typing.
    if (deployedAtBlock === null) {
      p.deployedAtBlock = ZERO;
    } else {
      p.deployedAtBlock = deployedAtBlock as BigInt;
    }

    // Required core addresses (filled opportunistically by handlers).
    p.claimToken = ZERO_ADDRESS;
    p.veClaimNft = ZERO_ADDRESS;
    p.mineCore = ZERO_ADDRESS;
    p.shareholderRoyalties = ZERO_ADDRESS;
    p.furnace = ZERO_ADDRESS;
    p.marketRouter = ZERO_ADDRESS;

    // Back-compat alias (required by schema). Zero address until Furnace wiring is observed.
    p.entryTokenRegistry = ZERO_ADDRESS;

    // Flags
    p.takeoversPaused = false;
    p.lockingPaused = false;
    p.tradingPaused = false;

    ensureInfoSurfaces();
  }

  // ---------------------------------------------------------------------------
  // Backfill required alias fields (safety for stores created before v1.0.0)
  // ---------------------------------------------------------------------------
  // Protocol.entryTokenRegistry is a required, backwards-compatible alias that MUST equal
  // furnaceEntryTokenRegistry when known. When the registry is still unknown, use the
  // zero address sentinel.
  let didBackfill = false;
  if (p.get('entryTokenRegistry') == null) {
    if (p.furnaceEntryTokenRegistry !== null) {
      p.entryTokenRegistry = p.furnaceEntryTokenRegistry as Bytes;
    } else {
      p.entryTokenRegistry = ZERO_ADDRESS;
    }
    didBackfill = true;
  } else if (p.furnaceEntryTokenRegistry !== null) {
    const fe = p.furnaceEntryTokenRegistry as Bytes;
    const currentEntryTokenRegistry = p.entryTokenRegistry;
    if (
      currentEntryTokenRegistry === null ||
      currentEntryTokenRegistry.toHexString() != fe.toHexString()
    ) {
      p.entryTokenRegistry = fe;
      didBackfill = true;
    }
  }

  if (created || didBackfill) {
    p.save();
  }

  return p as Protocol;
}

export function setBytesIfZero(current: Bytes, next: Bytes): Bytes {
  return isZeroAddressBytes(current) ? next : current;
}
