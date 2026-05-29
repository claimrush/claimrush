import { Address, BigInt } from "@graphprotocol/graph-ts";

import { User } from "../generated/schema";

const ZERO = BigInt.fromI32(0);

function shortAddress(hex: string): string {
  // Expect 0x + 40 hex chars.
  if (hex.length <= 10) {
    return hex;
  }
  const prefix = hex.substr(0, 6);
  const suffix = hex.substr(hex.length - 4, 4);
  return prefix + "..." + suffix;
}

export function loadOrCreateUser(addr: Address): User {
  const id = addr.toHexString();
  let u = User.load(id);

  if (u == null) {
    u = new User(id);
    u.address = addr;

    // Display helpers (basename/ens are off-chain; default to short address).
    u.displayName = shortAddress(id);

    // Aggregates (lifetime)
    u.takeoverCount = 0;
    u.ethSpentOnTakeoversWei = ZERO;
    u.kingClaimMinedWei = ZERO;
    u.longestReignSeconds = 0;

    u.shareholderEthClaimedWei = ZERO;
    u.furnaceEthInWei = ZERO;
    u.furnacePrincipalClaimInWei = ZERO;

    // Optional ve state: initialize to 0 so leaderboards can sort deterministically.
    u.veBalanceWei = ZERO;
    u.totalLockedClaimWei = ZERO;

    u.save();
  } else {
    // Backfill optional fields for stores created before these snapshots existed.
    let didBackfill = false;

    if (u.displayName === null) {
      u.displayName = shortAddress(id);
      didBackfill = true;
    }

    if (u.veBalanceWei === null) {
      u.veBalanceWei = ZERO;
      didBackfill = true;
    }

    if (u.totalLockedClaimWei === null) {
      u.totalLockedClaimWei = ZERO;
      didBackfill = true;
    }

    if (didBackfill) {
      u.save();
    }
  }

  return u as User;
}
