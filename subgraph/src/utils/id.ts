import { ethereum } from "@graphprotocol/graph-ts";

// chain and prevents collisions across event types. This is the recommended pattern.
// However, if two Graph Node deployments index overlapping data sources that emit
// events with the same txHash-logIndex, entity ID collisions could occur.
// Mitigation: ensure each data source indexes a distinct contract address.
export function eventId(event: ethereum.Event): string {
  return event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
}
