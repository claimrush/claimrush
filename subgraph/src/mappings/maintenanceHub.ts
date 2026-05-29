import { BigInt, Bytes } from "@graphprotocol/graph-ts";

import { Poked } from "../generated/MaintenanceHub/MaintenanceHub";

import { MaintenancePokedEvent } from "../generated/schema";

import { eventId } from "../utils/id";
import { loadOrCreateProtocol, setBytesIfZero } from "../utils/protocol";
import { loadOrCreateUser } from "../utils/user";

function touchMaintenanceHubAddress(addr: Bytes, blockNumber: BigInt): void {
  const protocol = loadOrCreateProtocol(blockNumber);
  const current = protocol.maintenanceHub;
  if (current === null) {
    protocol.maintenanceHub = addr;
  } else {
    protocol.maintenanceHub = setBytesIfZero(current as Bytes, addr);
  }
  protocol.save();
}

export function handlePoked(event: Poked): void {
  touchMaintenanceHubAddress(event.address, event.block.number);

  const id = eventId(event);
  const caller = loadOrCreateUser(event.params.caller);

  const e = new MaintenancePokedEvent(id);
  e.caller = caller.id;
  e.checkpointOk = event.params.checkpointOk;
  e.flushOk = event.params.flushOk;
  e.offersAttempted = event.params.offersAttempted;
  e.offersSucceeded = event.params.offersSucceeded;
  e.furnaceTickSucceeded = event.params.furnaceTickSucceeded;
  e.bountyWethForwarded = event.params.bountyWethForwarded;
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.save();
}
