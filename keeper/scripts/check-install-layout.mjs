#!/usr/bin/env node
/* global console, process */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const keeperRoot = path.resolve(scriptDir, '..');
const repoRoot = path.resolve(keeperRoot, '..');

const required = [
  {
    path: path.join(repoRoot, 'packages', 'node-utils', 'package.json'),
    description: '@claimrush/node-utils local file dependency',
  },
  {
    path: path.join(repoRoot, 'deployments'),
    description: 'deployments manifest directory',
  },
];

const missing = required.filter((entry) => !fs.existsSync(entry.path));
if (missing.length > 0) {
  console.error('[keeper] Install layout check failed.');
  console.error('[keeper] Missing required repo-relative paths:');
  for (const entry of missing) {
    console.error(`  - ${entry.description}: ${entry.path}`);
  }
  console.error('');
  console.error('[keeper] Install this package inside the ClaimRush repo layout, for example:');
  console.error('  ~/claimrush/keeper');
  console.error('with these sibling repo paths preserved:');
  console.error('  ~/claimrush/packages/node-utils');
  console.error('  ~/claimrush/deployments');
  console.error('');
  console.error('[keeper] Copying only keeper/ into a standalone directory will fail.');
  process.exit(1);
}
