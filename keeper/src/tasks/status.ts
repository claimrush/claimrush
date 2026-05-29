import fs from 'node:fs';

import { loadJson } from '../shared/state.js';

export function readStatus({ statusPath }: { statusPath: string }): unknown {
  return loadJson(statusPath, { fallback: null });
}

export function printStatus({
  statusPath,
  log = console.log,
}: {
  statusPath: string;
  log?: (msg: string) => void;
}): unknown {
  if (!fs.existsSync(statusPath)) {
    log(`no status file: ${statusPath}`);
    return null;
  }
  const s = readStatus({ statusPath });
  log(JSON.stringify(s, null, 2));
  return s;
}
