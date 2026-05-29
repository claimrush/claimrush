import { BigInt } from '@graphprotocol/graph-ts';

import { ActivityItem } from '../generated/schema';

const ACTIVITY_SORT_TIMESTAMP_WIDTH = 20;

function padTimestamp(value: string): string {
  let out = value;
  while (out.length < ACTIVITY_SORT_TIMESTAMP_WIDTH) {
    out = '0' + out;
  }
  return out;
}

export function activitySortKey(timestamp: BigInt, id: string): string {
  return padTimestamp(timestamp.toString()) + ':' + id;
}

export function saveActivityItem(item: ActivityItem): void {
  item.sortKey = activitySortKey(item.timestamp, item.id);
  item.save();
}
