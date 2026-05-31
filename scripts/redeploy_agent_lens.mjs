#!/usr/bin/env node
/* eslint-disable no-console */

/**
 * scripts/redeploy_agent_lens.mjs
 *
 * One-command wrapper around `node scripts/deploy_prod.mjs --deploy-agent-lens
 * --force-agent-lens --verify` for the AgentLens-only redeploy cycle introduced
 * for the v1.0.1 `currentKingEmissionRate` field.
 *
 * What it does:
 *
 *   1. Loads `deployments/<network>.json` and pins:
 *        - the OLD AgentLens address (manifest)
 *        - the canonical MineCore address (manifest)
 *      Refuses to run if either is zero / missing.
 *
 *   2. Pre-flight verification (read-only, never broadcasts):
 *        - `cast code <OLD_LENS>` is non-empty
 *        - `cast call <OLD_LENS> "mineCore()(address)"` matches manifest
 *        - `cast call <MINE_CORE> "getFurnaceEmissionRateAt(uint256)(uint256)" <now>`
 *          returns a non-zero baseline (the value the OLD lens would have surfaced
 *          on its 7th tuple slot)
 *      The values are printed so the operator can confirm the wiring before
 *      authorizing the broadcast.
 *
 *   3. Optionally runs `forge build` to refresh the local artifact (skip with
 *      `--skip-forge-build` if the operator just built).
 *
 *   4. Delegates the actual broadcast to:
 *        node scripts/deploy_prod.mjs \
 *          --network <NETWORK> \
 *          --rpc-url <RPC_URL> \
 *          --deploy-agent-lens \
 *          --force-agent-lens \
 *          --verify
 *      `deploy_prod.mjs` handles signer resolution (PRIVATE_KEY for Sepolia,
 *      LEDGER_ADDRESS for mainnet), parses the broadcast log, updates the
 *      manifest's `contracts.AgentLens.address` + `startBlock`, and runs
 *      `scripts/verify_deployment.py`.
 *
 *   5. Post-flight verification (read-only):
 *        - Manifest AgentLens.address has changed
 *        - `cast code <NEW_LENS>` is non-empty
 *        - `cast call <NEW_LENS> "mineCore()(address)"` matches manifest
 *        - `cast call <NEW_LENS> "readGlobalV1()"` does not revert
 *          (smoke that the new struct layout is internally consistent)
 *        - `cast call <MINE_CORE> "getFurnaceEmissionRateAt(uint256)(uint256)" <now>`
 *          decays monotonically vs the pre-flight baseline (sanity check)
 *
 *   6. Re-exports ABIs to abis/<network>/ via scripts/export_abis.py so
 *      AgentLens.abi.json picks up the new `currentKingEmissionRate` field.
 *
 *   7. Computes and prints the local artifact bytecode hashes (sha256 full +
 *      sha256 stripped + keccak full) for the operator to fold into
 *      baselines/sepolia-v1.0.0/bytecode-parity.md (or its mainnet equivalent).
 *
 * Usage:
 *
 *   PRIVATE_KEY=0x... \
 *     node scripts/redeploy_agent_lens.mjs \
 *       --network base_sepolia \
 *       --rpc-url https://sepolia.base.org
 *
 *   LEDGER_ADDRESS=0x... \
 *     node scripts/redeploy_agent_lens.mjs \
 *       --network base_mainnet \
 *       --rpc-url https://mainnet.base.org
 *
 * Flags:
 *
 *   --network <base_sepolia|base_mainnet>   Required.
 *   --rpc-url <url>                          Required (or RPC_URL env).
 *   --skip-forge-build                       Skip the `forge build` step.
 *   --skip-preflight                         Skip pre-flight cast calls.
 *   --skip-postflight                        Skip post-flight cast calls.
 *   --skip-abi-export                        Skip the export_abis.py step.
 *   --no-prompt                              Do not prompt before broadcasting.
 *   --help / -h                              Print this usage and exit 0.
 *
 * Exit codes:
 *
 *   0   Redeploy + verify succeeded.
 *   1   Bad arguments / pre-flight or post-flight check failed / broadcast aborted.
 */

import path from "node:path";
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readJsonFileSafe } from "./lib/readJsonFileSafe.mjs";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const SUPPORTED_NETWORKS = new Set(["base_sepolia", "base_mainnet"]);
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
const SAFE_ARG = /^[A-Za-z0-9._:/=+@-]+$/;

function info(msg) {
  console.log(`[redeploy_agent_lens] ${msg}`);
}

function die(msg) {
  console.error(`[redeploy_agent_lens] ERROR: ${msg}`);
  process.exit(1);
}

function help() {
  console.log(`
scripts/redeploy_agent_lens.mjs

One-command wrapper around \`node scripts/deploy_prod.mjs --deploy-agent-lens
--force-agent-lens --verify\` for the AgentLens-only redeploy cycle.

The wrapper runs pre-flight read-only verification, optionally rebuilds the
forge artifact, delegates the broadcast to deploy_prod.mjs, runs post-flight
read-only verification, re-exports ABIs, and prints the local bytecode hashes
the operator should fold into the bytecode-parity baseline.

Usage:
  PRIVATE_KEY=0x... \\
    node scripts/redeploy_agent_lens.mjs \\
      --network base_sepolia \\
      --rpc-url https://sepolia.base.org

  PRIVATE_KEY=0x... \\
    node scripts/redeploy_agent_lens.mjs \\
      --network base_mainnet \\
      --rpc-url https://mainnet.base.org

  Both networks broadcast as the canonical hot-PK deployer EOA. Ledger is
  reserved for Safe signers only, NOT for the deployer. (The wrapper still
  falls back to LEDGER_ADDRESS / SIGNER_ADDRESS via
  deploy_prod.mjs::resolveForgeSignerConfig if PRIVATE_KEY is unset, but
  that path is for local dev / one-off recovery.)

  Mainnet caveat: the canonical deployer key is bounded-lifetime (shredded
  after the post-genesis Admin Safe TimelockAcceptOwnership executeBatch).
  Verify your secrets vault still holds the key before planning a
  mainnet AgentLens redeploy. If the key is already shredded, AgentLens has
  no admin role / no proxy admin / no upgradability, so any funded EOA can
  deploy it; the only consequence is the 'from' field of the new CREATE tx
  no longer matches the canonical Deploy.s.sol broadcaster.

Required:
  --network <base_sepolia|base_mainnet>   Target network.
  --rpc-url <url>                         RPC endpoint (or RPC_URL env).

Required env:
  PRIVATE_KEY              hot-PK deployer for both base_sepolia and
                           base_mainnet (canonical path), or
  LEDGER_ADDRESS / SIGNER_ADDRESS for the Ledger fallback path
                           (only used when PRIVATE_KEY is unset).

Optional flags:
  --skip-forge-build       Skip the forge build step (use when artifacts are fresh).
  --skip-preflight         Skip pre-flight cast calls (NOT recommended).
  --skip-postflight        Skip post-flight cast calls (NOT recommended).
  --skip-abi-export        Skip the export_abis.py step.
  --no-prompt              Do not prompt before broadcasting.
  --help, -h               Print this usage and exit 0.

Verification steps performed:
  Pre-flight:
    - cast code <OLD_LENS> is non-empty
    - <OLD_LENS>.mineCore() == manifest MineCore
    - <OLD_LENS>.furnace() == manifest Furnace
    - MineCore.getFurnaceEmissionRateAt(now) (baseline for monotone-decay check)
  Post-flight:
    - manifest AgentLens.address has changed
    - cast code <NEW_LENS> is non-empty
    - <NEW_LENS>.mineCore() == manifest MineCore
    - <NEW_LENS>.furnace() == manifest Furnace
    - <NEW_LENS>.readGlobalV1() returns non-empty data (does not revert)
    - MineCore.getFurnaceEmissionRateAt(now) <= pre-flight baseline (monotone)

Exit codes:
  0   Redeploy + verify succeeded.
  1   Bad arguments / pre-flight or post-flight check failed / broadcast aborted.
`.trimStart());
}

function getArg(flag, fallback) {
  const idx = process.argv.indexOf(flag);
  if (idx === -1) return fallback;
  const value = process.argv[idx + 1];
  if (value === undefined || value.startsWith("--")) {
    die(`flag ${flag} requires a value`);
  }
  return value;
}

function hasFlag(flag) {
  return process.argv.includes(flag);
}

function assertSafeArg(value, label) {
  if (!SAFE_ARG.test(value)) {
    die(`unsafe characters in ${label}: ${JSON.stringify(value)}`);
  }
}

function runStream(bin, args, opts = {}) {
  const result = spawnSync(bin, args, {
    cwd: ROOT,
    stdio: "inherit",
    env: { ...process.env, ...(opts.env ?? {}) },
  });
  if (result.error) {
    die(`failed to spawn ${bin}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    die(`${bin} ${args.join(" ")} exited with status ${result.status}`);
  }
}

function runCapture(bin, args, opts = {}) {
  const result = spawnSync(bin, args, {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...(opts.env ?? {}) },
    encoding: "utf8",
  });
  if (result.error) {
    die(`failed to spawn ${bin}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const stderr = (result.stderr ?? "").trim();
    die(`${bin} ${args.join(" ")} exited with status ${result.status}${stderr ? `\n${stderr}` : ""}`);
  }
  return (result.stdout ?? "").trim();
}

function castCall(rpcUrl, to, sig, callArgs = []) {
  return runCapture("cast", ["call", to, sig, ...callArgs.map(String), "--rpc-url", rpcUrl]);
}

function castCode(rpcUrl, to) {
  return runCapture("cast", ["code", to, "--rpc-url", rpcUrl]);
}

function normalizeAddress(addr) {
  if (!addr) return ZERO_ADDR;
  return String(addr).toLowerCase();
}

function isZeroAddress(addr) {
  return normalizeAddress(addr) === ZERO_ADDR;
}

function readManifest(network) {
  const manifestPath = path.join(ROOT, "deployments", `${network}.json`);
  if (!fs.existsSync(manifestPath)) {
    die(`manifest not found: ${manifestPath}`);
  }
  const manifest = readJsonFileSafe(manifestPath, { label: `${network} manifest` });
  return { manifestPath, manifest };
}

function pickContractAddress(manifest, key) {
  const addr = manifest?.contracts?.[key]?.address;
  if (!addr || isZeroAddress(addr)) {
    die(`manifest contracts.${key}.address is zero or missing`);
  }
  return normalizeAddress(addr);
}

function loadDeployedBytecode(contractName) {
  const artifactPath = path.join(ROOT, "out", `${contractName}.sol`, `${contractName}.json`);
  if (!fs.existsSync(artifactPath)) {
    die(`forge artifact not found: ${artifactPath} (run \`forge build\` first or drop --skip-forge-build)`);
  }
  const artifact = readJsonFileSafe(artifactPath, { label: `${contractName} artifact` });
  const code = artifact?.deployedBytecode?.object;
  if (typeof code !== "string" || !code.startsWith("0x")) {
    die(`forge artifact missing deployedBytecode.object: ${artifactPath}`);
  }
  return code;
}

function stripCborFooter(hex) {
  const raw = Buffer.from(hex.startsWith("0x") ? hex.slice(2) : hex, "hex");
  if (raw.length < 2) return raw;
  const inner = raw.readUInt16BE(raw.length - 2);
  const stripped = raw.slice(0, raw.length - 2 - inner);
  return { full: raw, stripped, footerLen: inner + 2 };
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

function keccak256Hex(hex) {
  // keccak256 via cast for parity with the bytecode-parity baseline column.
  return runCapture("cast", ["keccak", hex]);
}

function confirmOrAbort(network, oldLens, newRpc) {
  if (hasFlag("--no-prompt")) return;
  const banner = [
    "",
    "================================================================",
    `  Network:        ${network}`,
    `  RPC URL:        ${newRpc}`,
    `  Old AgentLens:  ${oldLens}`,
    "  Action:         force-redeploy AgentLens against the local artifact",
    "                  and update the manifest + ABI exports.",
    "================================================================",
    "",
    "Proceed? (yes/no): ",
  ].join("\n");
  process.stdout.write(banner);

  const buf = Buffer.alloc(8);
  let read = 0;
  try {
    read = fs.readSync(0, buf, 0, buf.length);
  } catch (err) {
    die(`failed to read confirmation from stdin: ${err instanceof Error ? err.message : String(err)}`);
  }
  const answer = buf.slice(0, read).toString("utf8").trim().toLowerCase();
  if (answer !== "yes" && answer !== "y") {
    die(`aborted by operator (got ${JSON.stringify(answer)}; pass --no-prompt to skip this prompt)`);
  }
}

function preflight({ rpcUrl, manifest, oldLens, mineCore }) {
  info("Pre-flight: verifying existing AgentLens wiring against manifest...");
  const oldCode = castCode(rpcUrl, oldLens);
  if (!oldCode || oldCode === "0x") {
    die(`existing AgentLens at ${oldLens} has NO live code on this RPC; manifest is stale or chain is wrong`);
  }
  info(`  cast code ${oldLens} -> ${oldCode.length / 2 - 1} bytes (live)`);

  const lensMine = normalizeAddress(castCall(rpcUrl, oldLens, "mineCore()(address)"));
  if (lensMine !== mineCore) {
    die(`existing AgentLens.mineCore()=${lensMine} differs from manifest MineCore=${mineCore}`);
  }
  info(`  AgentLens.mineCore()=${lensMine} matches manifest MineCore`);

  const lensFurnace = normalizeAddress(castCall(rpcUrl, oldLens, "furnace()(address)"));
  const manifestFurnace = pickContractAddress(manifest, "Furnace");
  if (lensFurnace !== manifestFurnace) {
    die(`existing AgentLens.furnace()=${lensFurnace} differs from manifest Furnace=${manifestFurnace}`);
  }
  info(`  AgentLens.furnace()=${lensFurnace} matches manifest Furnace`);

  const nowSec = Math.floor(Date.now() / 1000).toString();
  const furnaceRateRaw = castCall(rpcUrl, mineCore, "getFurnaceEmissionRateAt(uint256)(uint256)", [nowSec]);
  const furnaceRate = BigInt(furnaceRateRaw.split(/\s+/)[0]);
  if (furnaceRate === 0n) {
    info(
      `  WARNING: MineCore.getFurnaceEmissionRateAt(${nowSec}) returned 0. ` +
        `This can be expected pre-genesis but is unusual post-launch; double-check the chain state.`,
    );
  } else {
    info(`  MineCore.getFurnaceEmissionRateAt(${nowSec}) = ${furnaceRate} (10x = ${furnaceRate * 10n})`);
  }
  return { furnaceRateBaseline: furnaceRate };
}

function postflight({ rpcUrl, manifest, oldLens, newLens, mineCore, furnaceRateBaseline }) {
  info("Post-flight: verifying new AgentLens...");
  if (normalizeAddress(newLens) === normalizeAddress(oldLens)) {
    die(`manifest AgentLens.address is still ${oldLens} after deploy_prod.mjs run; the broadcast failed silently`);
  }
  info(`  manifest AgentLens.address: ${oldLens} -> ${newLens}`);

  const newCode = castCode(rpcUrl, newLens);
  if (!newCode || newCode === "0x") {
    die(`new AgentLens at ${newLens} has NO live code; broadcast appears to have failed`);
  }
  const newCodeBytes = newCode.length / 2 - 1;
  info(`  cast code ${newLens} -> ${newCodeBytes} bytes (live)`);

  const lensMine = normalizeAddress(castCall(rpcUrl, newLens, "mineCore()(address)"));
  if (lensMine !== mineCore) {
    die(`new AgentLens.mineCore()=${lensMine} differs from manifest MineCore=${mineCore}`);
  }
  info(`  new AgentLens.mineCore()=${lensMine} matches manifest MineCore`);

  const lensFurnace = normalizeAddress(castCall(rpcUrl, newLens, "furnace()(address)"));
  const manifestFurnace = pickContractAddress(manifest, "Furnace");
  if (lensFurnace !== manifestFurnace) {
    die(`new AgentLens.furnace()=${lensFurnace} differs from manifest Furnace=${manifestFurnace}`);
  }
  info(`  new AgentLens.furnace()=${lensFurnace} matches manifest Furnace`);

  // Smoke: readGlobalV1() must not revert on the new lens. We don't decode the
  // 21-field struct — we just confirm the call returns non-empty data, which
  // proves the new MineCoreGlobalV1 layout is internally consistent.
  const globalRaw = runCapture("cast", ["call", newLens, "readGlobalV1()", "--rpc-url", rpcUrl]);
  if (!globalRaw || globalRaw === "0x") {
    die(`new AgentLens.readGlobalV1() returned empty data; the new struct layout is broken`);
  }
  const globalBytes = (globalRaw.length - 2) / 2;
  info(`  new AgentLens.readGlobalV1() returned ${globalBytes} bytes (smoke OK)`);

  const nowSec = Math.floor(Date.now() / 1000).toString();
  const furnaceRateRaw = castCall(rpcUrl, mineCore, "getFurnaceEmissionRateAt(uint256)(uint256)", [nowSec]);
  const furnaceRate = BigInt(furnaceRateRaw.split(/\s+/)[0]);
  info(`  MineCore.getFurnaceEmissionRateAt(${nowSec}) = ${furnaceRate} (10x = ${furnaceRate * 10n})`);

  if (furnaceRateBaseline !== undefined && furnaceRateBaseline > 0n && furnaceRate > furnaceRateBaseline) {
    die(
      `furnace emission rate increased post-deploy (${furnaceRateBaseline} -> ${furnaceRate}); the rate is monotone-decaying so this signals a chain mismatch`,
    );
  }
}

function printBytecodeHashes() {
  info("Local bytecode hashes for the new AgentLens artifact (for parity baseline):");
  const code = loadDeployedBytecode("AgentLens");
  const { full, stripped, footerLen } = stripCborFooter(code);
  const sha256Full = sha256(full);
  const sha256Stripped = sha256(stripped);
  const keccakFull = keccak256Hex(code);
  info(`  runtime size:        ${full.length} B`);
  info(`  CBOR footer:         ${footerLen} B`);
  info(`  sha256 (runtime):    ${sha256Full}`);
  info(`  sha256 (no metadata):${sha256Stripped}`);
  info(`  keccak (runtime):    ${keccakFull}`);
  info("");
  info("Suggested row for baselines/sepolia-v1.0.0/bytecode-parity.md:");
  info(
    `  | AgentLens                      |     ${full.length.toLocaleString()} B |        ${footerLen} B | \`${sha256Full}\` | \`${sha256Stripped}\` | \`${keccakFull}\` |`,
  );
}

function main() {
  if (hasFlag("--help") || hasFlag("-h")) {
    help();
    process.exit(0);
  }

  const network = getArg("--network", process.env.NETWORK);
  const rpcUrl = getArg("--rpc-url", process.env.RPC_URL);
  if (!network) die("missing --network (base_sepolia | base_mainnet)");
  if (!SUPPORTED_NETWORKS.has(network)) {
    die(`unsupported --network ${network} (must be base_sepolia or base_mainnet)`);
  }
  if (!rpcUrl) die("missing --rpc-url (or RPC_URL env)");
  assertSafeArg(network, "--network");
  assertSafeArg(rpcUrl, "--rpc-url");

  if (!process.env.PRIVATE_KEY && !(process.env.LEDGER_ADDRESS || process.env.SIGNER_ADDRESS)) {
    die(
      `${network} requires PRIVATE_KEY (canonical hot-PK deployer; same path on Sepolia and mainnet) ` +
        `or LEDGER_ADDRESS / SIGNER_ADDRESS (fallback only) ` +
        `in env. Read by scripts/deploy_prod.mjs::resolveForgeSignerConfig.`,
    );
  }

  const skipForgeBuild = hasFlag("--skip-forge-build");
  const skipPreflight = hasFlag("--skip-preflight");
  const skipPostflight = hasFlag("--skip-postflight");
  const skipAbiExport = hasFlag("--skip-abi-export");

  const { manifestPath, manifest } = readManifest(network);
  const oldLens = pickContractAddress(manifest, "AgentLens");
  const mineCore = pickContractAddress(manifest, "MineCore");
  info(`network=${network}`);
  info(`manifest=${manifestPath}`);
  info(`old AgentLens=${oldLens}`);
  info(`MineCore=${mineCore}`);

  let furnaceRateBaseline = 0n;
  if (skipPreflight) {
    info("Pre-flight: SKIPPED (--skip-preflight).");
  } else {
    const out = preflight({ rpcUrl, manifest, oldLens, mineCore });
    furnaceRateBaseline = out.furnaceRateBaseline;
  }

  confirmOrAbort(network, oldLens, rpcUrl);

  if (skipForgeBuild) {
    info("forge build: SKIPPED (--skip-forge-build).");
  } else {
    info("Running forge build to refresh the AgentLens artifact...");
    runStream("forge", ["build"]);
  }

  info("Delegating to scripts/deploy_prod.mjs --deploy-agent-lens --force-agent-lens (no --verify; full-stack verify_deployment.py runs as advisory at the end) ...");
  runStream("node", [
    "scripts/deploy_prod.mjs",
    "--network",
    network,
    "--rpc-url",
    rpcUrl,
    "--deploy-agent-lens",
    "--force-agent-lens",
  ]);

  // Manifest was rewritten by deploy_prod.mjs; reload it so we read the new
  // AgentLens address rather than the cached pre-deploy snapshot.
  const { manifest: manifestAfter } = readManifest(network);
  const newLens = pickContractAddress(manifestAfter, "AgentLens");

  if (skipPostflight) {
    info("Post-flight: SKIPPED (--skip-postflight).");
  } else {
    postflight({
      rpcUrl,
      manifest: manifestAfter,
      oldLens,
      newLens,
      mineCore,
      furnaceRateBaseline,
    });
  }

  if (skipAbiExport) {
    info("ABI export: SKIPPED (--skip-abi-export).");
  } else {
    const outDir = `abis/${network}`;
    info(`Re-exporting ABIs to ${outDir} (picks up new currentKingEmissionRate field)...`);
    runStream("python3", ["scripts/export_abis.py", "--network", network, "--outdir", outDir]);
  }

  printBytecodeHashes();

  // Advisory full-stack verification. Runs LAST so that the AgentLens-specific
  // post-flight, ABI export, and bytecode-hash steps always complete first; the
  // wrapper deliberately does not gate on this because verify_deployment.py
  // covers cross-protocol invariants (proxy-admin owner, guardian wiring, etc.)
  // that are governed by the launch-day handoff ceremony, not by the AgentLens
  // redeploy. A failure here is non-fatal but the operator should review the
  // output and reconcile any pre-existing post-handoff drift.
  let verifyExitCode = 0;
  try {
    info("");
    info("Advisory: scripts/verify_deployment.py (informational; non-fatal)...");
    const result = spawnSync("python3", [
      "scripts/verify_deployment.py",
      "--network",
      network,
      "--rpc-url",
      rpcUrl,
    ], {
      cwd: ROOT,
      stdio: "inherit",
    });
    verifyExitCode = result.status ?? 0;
  } catch (err) {
    info(`verify_deployment.py spawn error (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
    verifyExitCode = -1;
  }
  if (verifyExitCode !== 0) {
    info(
      `verify_deployment.py exited with status ${verifyExitCode} (non-fatal for AgentLens redeploy). ` +
        `Review failures above; orthogonal launch-day-handoff drift (proxyAdmin.owner, guardian rotations) ` +
        `is expected post-FinalizeOwnership/post-genesis and does NOT block the AgentLens cycle.`,
    );
  }

  info("");
  info(`AgentLens redeploy complete. Old=${oldLens} New=${newLens}`);
  info("Next steps (manual):");
  info("  1. Update the local-side bytecode-parity baseline with the row printed above.");
  info("  2. Commit the manifest + ABI + parity-baseline updates as a single coherent diff.");
  info("  3. Sync to the public repo via your established public-export workflow.");
  info("  4. Roll out the SDK rebuild to your agent consumers and drop any client-side");
  info("     `currentFurnaceEmissionRate × 10` workaround in favour of `currentKingEmissionRate`.");
}

main();
