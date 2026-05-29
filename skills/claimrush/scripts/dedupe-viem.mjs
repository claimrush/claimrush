#!/usr/bin/env node
/**
 * Replace the skill's own copy of `viem` (and `viem/_esm`, `viem/_types`,
 * `viem/_cjs`) with a symlink to the SDK's copy so TypeScript sees a single
 * type identity. This avoids the classic "Two different types with this name
 * exist, but they are unrelated" error when calling SDK functions that
 * accept viem clients (PublicClient/WalletClient).
 *
 * Runs as a post-install step. Idempotent: a no-op when the symlink already
 * points at the SDK's copy.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.resolve(here, '..');
const repoRoot = path.resolve(skillRoot, '..', '..');
const sdkViem = path.join(repoRoot, 'agents', 'sdk', 'node_modules', 'viem');
const skillViem = path.join(skillRoot, 'node_modules', 'viem');

if (!fs.existsSync(sdkViem)) {
  console.error(
    `[claimrush-skill dedupe-viem] SDK viem not found at ${sdkViem}. Run 'npm -C agents/sdk install' first.`,
  );
  process.exit(0);
}

if (fs.existsSync(skillViem)) {
  let already = false;
  try {
    const stat = fs.lstatSync(skillViem);
    if (stat.isSymbolicLink()) {
      const target = fs.readlinkSync(skillViem);
      const abs = path.resolve(path.dirname(skillViem), target);
      if (abs === sdkViem) already = true;
    }
  } catch {
    /* ignore */
  }
  if (already) {
    console.log('[claimrush-skill dedupe-viem] already symlinked');
    process.exit(0);
  }
  fs.rmSync(skillViem, { recursive: true, force: true });
}

fs.mkdirSync(path.dirname(skillViem), { recursive: true });
fs.symlinkSync(sdkViem, skillViem, 'dir');
console.log(`[claimrush-skill dedupe-viem] symlinked ${skillViem} -> ${sdkViem}`);
