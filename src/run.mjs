#!/usr/bin/env node
// Repo-root shim: allow `node ./src/run.mjs ...` from the repo root.
//
// The keeper lives at ./keeper/src/run.mjs, but this repo already has a `src/`
// directory (Solidity). Adding this small Node entrypoint avoids the common
// "Cannot find module ./src/run.mjs" footgun when running keeper commands.

import {spawn} from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const keeperRunner = path.resolve(__dirname, "../keeper/src/run.mjs");

if (!fs.existsSync(keeperRunner)) {
  console.error(`ERROR: keeper runner not found at: ${keeperRunner}`);
  process.exit(1);
}

const child = spawn(process.execPath, [keeperRunner, ...process.argv.slice(2)], {
  stdio: "inherit",
  env: process.env
});

child.on("error", (err) => {
  console.error(`ERROR: failed to start keeper runner: ${err?.message ?? String(err)}`);
  process.exit(1);
});

const SIGNAL_EXIT_CODES = {
  SIGINT: 130,
  SIGTERM: 143,
  SIGHUP: 129
};

// Forward common termination signals to the child.
// This helps when the repo-root shim is run under a process manager.
for (const sig of Object.keys(SIGNAL_EXIT_CODES)) {
  process.on(sig, () => {
    try {
      // `kill` is safe to call multiple times; it returns false if the process is already dead.
      child.kill(sig);
    } catch {
      // noop
    }
  });
}

child.on("exit", (code, signal) => {
  // Mirror the child exit status.
  if (signal) {
    process.exit(SIGNAL_EXIT_CODES[signal] ?? 1);
  }
  process.exit(code ?? 1);
});
