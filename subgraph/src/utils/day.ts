import { BigInt } from '@graphprotocol/graph-ts';

// Consumers displaying daily aggregates in local timezones must offset accordingly.
export const SECONDS_PER_DAY = 86400;

// Consumers displaying daily aggregates in local timezones must adjust accordingly.
export function dayIdFromTimestamp(ts: BigInt): string {
  return ts.div(BigInt.fromI32(SECONDS_PER_DAY)).toString();
}

export function dayStartFromDayId(dayId: string): BigInt {
  return BigInt.fromString(dayId).times(BigInt.fromI32(SECONDS_PER_DAY));
}
