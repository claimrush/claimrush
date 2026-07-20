/*
  Production deploy helper (v1.0.0)

  What it does:
    1) Confirms the RPC really points at the manifest chainId (fails closed on mismatch)
    2) (optional) Runs forge script Deploy.s.sol:Deploy for the core stack
    3) (optional) Parses Foundry broadcast artifacts to collect addresses + start blocks
       and writes deployments/<network>.json when you just deployed or pass
       --refresh-manifest-from-broadcast explicitly
    4) (optional) Runs Wire.s.sol for the first post-deploy wiring pass
    5) (optional) Deploys MaintenanceHub AFTER wiring, updates the manifest, then reruns Wire.s.sol
    6) (optional) Refreshes wire-derived helper metadata (for example FurnaceQuoter and immutable recipient pins)
    7) (optional) Ensures AgentLens is deployed against the final wired bundle
    8) (optional) Runs verify_deployment.py

  What it intentionally does NOT do:
    - It does not call LaunchController.finalizeGenesis(). That step is delayed until the
      10-day genesis accrual window ends and must be executed separately via
      script/FinalizeGenesis.s.sol:FinalizeGenesis.
    - On Base Sepolia, Deploy.s.sol auto-creates the CLAIM/WETH pool during deployment
      (the pool is materialized before vault constructors that require it).
    - On Base mainnet, the CLAIM/WETH pool address is deterministic but the pool is
      expected to be materialized during finalizeGenesis(). Until it has live code,
      this helper keeps aerodrome.claimWethPool / aerodrome.lpToken unset in the
      manifest so downstream consumers cannot confuse a CREATE2 prediction for a live pool.

  Runtime deployment model:
    - ClaimToken and VeClaimNFT are direct/permanent roots.
    - MineCore, Furnace, MarketRouter, and ShareholderRoyalties are deployed as
      implementation contracts plus named transparent proxies.
    - The deployments manifest treats contracts.<Name>.address as the live proxy
      address for that runtime quartet and also records implementation/proxyAdmin.
*/

import fs from "fs";
import path from "path";
import { spawnSync } from "child_process";
import { readJsonFileSafe } from "./lib/readJsonFileSafe.mjs";
import {
  parseStrictNonNegativeSafeInteger,
  parseStrictPositiveSafeInteger,
} from "./lib/strictNumbers.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const SUPPORTED_NETWORKS = new Set(["base_mainnet", "base_sepolia"]);
const EIP1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const EIP1967_ADMIN_SLOT =
  "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

function die(msg) {
  console.error(`\n[deploy_prod] ${msg}`);
  process.exit(1);
}

function hasFlag(flag) {
  return process.argv.includes(flag);
}

function help() {
  console.log(`
Usage:
  node scripts/deploy_prod.mjs --network <base_mainnet|base_sepolia> --rpc-url <url> [--deploy] [--wire] [--deploy-agent-lens] [--verify]

Options:
  --deploy                         Run Deploy.s.sol and refresh the manifest from broadcast
  --wire                           Run Wire.s.sol, deploy/reuse MaintenanceHub, refresh helper state, and ensure AgentLens is deployed
  --verify                         Run scripts/verify_deployment.py after deploy/wire
  --deploy-agent-lens             Deploy or refresh AgentLens as a standalone helper-only step
  --force-agent-lens              When combined with --deploy-agent-lens, force-redeploy AgentLens
                                  even when the manifest-pinned address still has live code that
                                  matches the current canonical bundle. Use this for AgentLens-only
                                  source upgrades (e.g. new struct fields) where the immutable
                                  wiring is unchanged but the runtime bytecode has shifted.
  --refresh-manifest-from-broadcast
                                   Rebuild deployments/<network>.json from an explicit timestamped Deploy.s.sol broadcast
  --refresh-live-state             Refresh live-derived manifest metadata (pool/timelock roots) from the current chain
  --deploy-broadcast-file <path>   Exact Deploy.s.sol broadcast file (run-<timestamp>.json; never run-latest.json)
  --timelock-broadcast-file <path> Exact DeployTimelock.s.sol broadcast file (run-<timestamp>.json; never run-latest.json)
  --minecorequoter-broadcast-file <path>
                                   Exact legacy DeployMineCoreQuoter.s.sol broadcast file for old refreshes
  --finalize-broadcast-file <path> Exact FinalizeGenesis.s.sol broadcast file to pin the live pool startBlock
  --no-sync                        Skip syncing generated deployment docs and downstream mirrors after manifest writes
  --no-deploy                      Skip Deploy.s.sol even if --deploy is present
  --network <name>                 base_mainnet or base_sepolia
  --rpc-url <url>                  RPC endpoint for the selected network
  --help                           Show this help
`);
}

function getArg(flag, fallback = undefined) {
  const idx = process.argv.indexOf(flag);
  if (idx === -1) return fallback;
  const v = process.argv[idx + 1];
  if (!v || v.startsWith("--")) return fallback;
  return v;
}

function readJson(p) {
  return readJsonFileSafe(p, {
    label: "deploy helper JSON input",
  });
}

function writeJson(p, obj) {
  const data = JSON.stringify(obj, null, 2) + "\n";
  const tmp = p + ".tmp." + process.pid;
  try {
    fs.writeFileSync(tmp, data);
    const fd = fs.openSync(tmp, "r");
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, p);
  } catch (err) {
    try { fs.unlinkSync(tmp); } catch {}
    throw err;
  }
}

function assertSafeShellArg(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    die(`${name} is empty or not a string`);
  }
  if (/[;&|`$(){}!#<>\n\r]/.test(value)) {
    die(`${name} contains unsafe shell characters`);
  }
}

function formatCommandForLog(bin, args) {
  return [bin, ...args.map((arg) => {
    const value = String(arg);
    return /[^A-Za-z0-9_./:=@+-]/.test(value) ? JSON.stringify(value) : value;
  })].join(" ");
}

function runArgs(bin, args, { env: extraEnv } = {}) {
  console.log(`\n$ ${formatCommandForLog(bin, args)}`);
  const result = spawnSync(bin, args, {
    stdio: "inherit",
    shell: false,
    env: extraEnv ? { ...process.env, ...extraEnv } : process.env,
  });
  if (result.status !== 0) {
    die(`command failed with exit code ${result.status}: ${formatCommandForLog(bin, args)}`);
  }
}

function runCaptureArgs(bin, args, { env } = {}) {
  const result = spawnSync(bin, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: env ? { ...process.env, ...env } : process.env,
  });
  if (result.status !== 0) {
    die(`${bin} ${args[0]} failed: ${(result.stderr || "").trim()}`);
  }
  return result.stdout.trim();
}

/**
 * Normalise a 20-byte hex address string.
 *
 * We return EIP-55-checksummed addresses (mixed case) so downstream manifest
 * fields are comparable with addresses produced by ethers/viem/cast, and so
 * casual diff tools do not report spurious "lowercase vs mixed-case" drift.
 * Zero addresses, non-hex inputs, and malformed strings are returned as-is
 * (after `ZERO` fallback) so callers can still detect those cases.
 */
/**
 * Normalise a 20-byte hex address string to EIP-55 mixed-case when possible.
 *
 * We prefer EIP-55 output so downstream manifest fields are comparable with
 * addresses produced by ethers/viem/cast, and so casual diff tools do not
 * report spurious "lowercase vs mixed-case" drift.
 *
 * Implementation notes:
 * - Node's built-in `sha3-256` is FIPS SHA3 (NOT Ethereum keccak-256), so we
 *   cannot rely on `crypto.createHash`.
 * - We dynamically load `keccak_256` from `ethereum-cryptography/keccak` if
 *   it is installed; otherwise we return the lowercase form.
 * - The dedicated gate `scripts/check_deployment_manifest_contract_keys.py`
 *   enforces EIP-55 on the committed manifest on every CI run, so any drift
 *   introduced by the fallback lowercase path fails the build.
 * - Zero addresses, non-hex inputs, and malformed strings are returned as-is
 *   (after the `ZERO` fallback) so callers can still detect those cases.
 */
function normalizeAddress(addr) {
  if (!addr) return ZERO;
  const a = String(addr).trim();
  if (!a.startsWith("0x") || a.length !== 42) return a;
  const hex = a.slice(2);
  if (!/^[0-9a-fA-F]{40}$/.test(hex)) return `0x${hex.toLowerCase()}`;
  const lower = hex.toLowerCase();
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports, global-require
    const { keccak_256 } = require("ethereum-cryptography/keccak");
    // eslint-disable-next-line @typescript-eslint/no-require-imports, global-require
    const { bytesToHex } = require("ethereum-cryptography/utils");
    const hashHex = bytesToHex(keccak_256(Buffer.from(lower, "ascii")));
    let out = "0x";
    for (let i = 0; i < 40; i++) {
      const c = lower[i];
      if (c >= "a" && c <= "f") {
        out += parseInt(hashHex[i], 16) >= 8 ? c.toUpperCase() : c;
      } else {
        out += c;
      }
    }
    return out;
  } catch {
    return `0x${lower}`;
  }
}

function isZeroAddress(addr) {
  return normalizeAddress(addr) === ZERO;
}

function toStartBlock(v) {
  return parseStrictNonNegativeSafeInteger(v, { defaultValue: 0, allowHex: true }) ?? 0;
}

function parseBroadcastBlockNumber(value) {
  return parseStrictNonNegativeSafeInteger(value, { defaultValue: 0, allowHex: true }) ?? 0;
}

function getBroadcastDir(scriptFile, chainId) {
  return path.join("broadcast", scriptFile, String(chainId));
}

function normalizePathForDisplay(p) {
  return path.normalize(p);
}

function assertExactBroadcastFile(p, label) {
  if (!p) die(`missing ${label} broadcast file path`);
  const normalized = path.normalize(p);
  if (path.basename(normalized) === "run-latest.json") {
    die(`${label} must point at an exact timestamped broadcast file (run-<timestamp>.json), not run-latest.json`);
  }
  if (!fs.existsSync(normalized)) {
    die(`missing ${label} broadcast artifact: ${normalized}`);
  }
  return normalized;
}

function listTimestampedBroadcastFiles(scriptFile, chainId) {
  const dir = getBroadcastDir(scriptFile, chainId);
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((name) => /^run-\d+\.json$/.test(name))
    .map((name) => ({
      path: path.join(dir, name),
      timestamp: parseStrictPositiveSafeInteger(name.slice(4, -5), { defaultValue: 0 }) ?? 0,
    }))
    .filter((entry) => Number.isFinite(entry.timestamp))
    .sort((a, b) => a.timestamp - b.timestamp);
}

function resolveFreshBroadcastFile(scriptFile, chainId, startedAtMs, label) {
  const candidates = listTimestampedBroadcastFiles(scriptFile, chainId);
  const fresh = candidates.filter((entry) => entry.timestamp >= startedAtMs);
  if (fresh.length === 0) {
    die(
      `could not find a fresh ${label} broadcast artifact after this run in ${normalizePathForDisplay(
        getBroadcastDir(scriptFile, chainId)
      )}`
    );
  }
  return fresh[fresh.length - 1].path;
}

// Deploy.s.sol CREATE order. On Sepolia, IPoolFactory.createPool() between
// the registry deployments and GenesisLPVault24M can cause Forge's name tracker
// to drift for the remaining CREATE transactions. We correct that using the
// known deployment order emitted by the script.
//
// NOTE: TimelockController is intentionally NOT in this list. Deploy.s.sol now
// resolves TimelockController from the TIMELOCK_ADDRESS env var (pre-deployed by
// script/DeployTimelock.s.sol in its own broadcast log). This works around a
// forge-broadcast trace-decoder bug that mis-aligns the
// LaunchController -> TimelockController CREATE pair when emitted from a single
// broadcast script (the decoder reads the tail of LC's runtime bytecode as TC's
// constructor args and aborts `--broadcast` before any tx is submitted).
// See script/DeployTimelock.s.sol and Deploy.s.sol::_resolveOrDeployTimelock.
const DEPLOY_SCRIPT_CREATE_ORDER = [
  "ClaimToken",
  "DexAdapter",
  "VeClaimNFT",
  "ShareholderRoyalties",
  "ShareholderRoyaltiesProxy",
  "FurnaceGuardHelper",
  "Furnace",
  "FurnaceProxy",
  "MarketRouter",
  "MarketRouterProxy",
  "MineCore",
  "MineCoreProxy",
  "MineCoreQuoter",
  "ClaimAllHelper",
  "DelegationHub",
  "EntryTokenRegistry",
  "EntryTokenRegistry",
  "GenesisLPVault24M",
  "LpStakingVault7D",
  "LaunchController",
];

function buildByName(runJson) {
  const byName = new Map();
  const receiptByHash = new Map();
  for (const rec of runJson.receipts ?? []) {
    const txHash = String(rec?.transactionHash ?? rec?.hash ?? "").toLowerCase();
    if (!txHash) continue;
    receiptByHash.set(txHash, rec);
  }

  const creates = [];
  for (const tx of runJson.transactions ?? []) {
    if (!tx?.contractName || !tx?.contractAddress) continue;
    const txHash = String(tx.hash ?? tx.transactionHash ?? "").toLowerCase();
    const receiptFallback = txHash ? receiptByHash.get(txHash) : null;
    const entry = {
      contractName: tx.contractName,
      contractAddress: normalizeAddress(tx.contractAddress),
      blockNumber: parseBroadcastBlockNumber(
        tx.receipt?.blockNumber ?? tx.blockNumber ?? receiptFallback?.blockNumber
      ),
      transactionType: tx.transactionType,
    };
    if (tx.transactionType === "CREATE") creates.push(entry);
    const arr = byName.get(entry.contractName) ?? [];
    arr.push(entry);
    byName.set(entry.contractName, arr);
  }

  repairNameDriftIfNeeded(byName, creates);
  return byName;
}

function repairNameDriftIfNeeded(byName, creates) {
  if (creates.length !== DEPLOY_SCRIPT_CREATE_ORDER.length) return;

  const expectedNames = new Map();
  for (const name of DEPLOY_SCRIPT_CREATE_ORDER) {
    expectedNames.set(name, (expectedNames.get(name) ?? 0) + 1);
  }

  const actualNames = new Map();
  for (const e of creates) {
    actualNames.set(e.contractName, (actualNames.get(e.contractName) ?? 0) + 1);
  }

  let hasMismatch = false;
  for (const [name, count] of expectedNames) {
    if ((actualNames.get(name) ?? 0) < count) {
      hasMismatch = true;
      break;
    }
  }
  if (!hasMismatch) return;

  console.warn(
    "[deploy_prod] WARNING: Forge broadcast contractName drift detected " +
      "(known issue when Deploy.s.sol triggers internal CREATE ops like testnet pool materialization). " +
      "Correcting names using known deployment order."
  );

  byName.clear();
  for (let i = 0; i < creates.length; i += 1) {
    const correctName = DEPLOY_SCRIPT_CREATE_ORDER[i];
    const entry = creates[i];
    const oldName = entry.contractName;
    if (oldName !== correctName) {
      console.warn(`  [fix] position ${i}: ${oldName} -> ${correctName} (${entry.contractAddress.slice(0, 10)}...)`);
    }
    entry.contractName = correctName;
    const arr = byName.get(correctName) ?? [];
    arr.push(entry);
    byName.set(correctName, arr);
  }
}

function pickLast(byName, contractName) {
  const arr = byName.get(contractName) ?? [];
  return arr.length ? arr[arr.length - 1] : null;
}

function pickLastN(byName, contractName, count) {
  const arr = byName.get(contractName) ?? [];
  return arr.length >= count ? arr.slice(-count) : [];
}

function requireNonZero(addr, what) {
  const a = normalizeAddress(addr);
  if (a === ZERO) {
    die(`missing ${what}`);
  }
  return a;
}

function castCall({ rpcUrl, to, sig, args = [] }) {
  const castArgs = ["call", to, sig, ...args.map(String), "--rpc-url", rpcUrl];
  return runCaptureArgs("cast", castArgs).trim();
}

function castAddressCall({ rpcUrl, to, sig, args = [] }) {
  return normalizeAddress(castCall({ rpcUrl, to, sig, args }));
}

function castBoolCall({ rpcUrl, to, sig, args = [] }) {
  const out = castCall({ rpcUrl, to, sig, args }).trim().toLowerCase();
  if (out === "true") return true;
  if (out === "false") return false;
  die(`failed to parse bool return from ${sig} @ ${to}: ${out}`);
}

function castUintCall({ rpcUrl, to, sig, args = [] }) {
  const out = castCall({ rpcUrl, to, sig, args }).replace(/\s*\[.*\]$/, "");
  const value = parseStrictNonNegativeSafeInteger(out, { defaultValue: null, allowHex: true });
  if (value == null) {
    die(`failed to parse uint return from ${sig} @ ${to}: ${out}`);
  }
  return value;
}

function castCode({ rpcUrl, to }) {
  return runCaptureArgs("cast", ["code", to, "--rpc-url", rpcUrl]);
}

function castStorage({ rpcUrl, to, slot }) {
  return runCaptureArgs("cast", ["storage", to, slot, "--rpc-url", rpcUrl]);
}

function readAddressSlot({ rpcUrl, to, slot, label }) {
  const raw = castStorage({ rpcUrl, to, slot }).toLowerCase();
  const hex = raw.startsWith("0x") ? raw.slice(2) : raw;
  if (!/^[0-9a-f]{64}$/.test(hex)) {
    die(`${label} returned malformed slot data: ${raw}`);
  }
  return normalizeAddress(`0x${hex.slice(24)}`);
}

function readProxyMetadata({ rpcUrl, proxy, label }) {
  return {
    implementation: readAddressSlot({
      rpcUrl,
      to: proxy,
      slot: EIP1967_IMPLEMENTATION_SLOT,
      label: `${label}.implementation`,
    }),
    proxyAdmin: readAddressSlot({
      rpcUrl,
      to: proxy,
      slot: EIP1967_ADMIN_SLOT,
      label: `${label}.proxyAdmin`,
    }),
  };
}

function hasLiveCode({ rpcUrl, to }) {
  if (isZeroAddress(to)) return false;
  const code = castCode({ rpcUrl, to }).trim();
  return code !== "0x";
}

function codeContainsAddress(codeHex, addr) {
  const normalized = normalizeAddress(addr);
  if (isZeroAddress(normalized)) return false;
  const frag = normalized.slice(2).toLowerCase();
  const padded = `000000000000000000000000${frag}`;
  const code = String(codeHex ?? "").toLowerCase();
  return code.includes(frag) || code.includes(padded);
}

function assertMaintenanceHubRuntimeMatches({ rpcUrl, maintenanceHubAddr, manifestPath, expected }) {
  const expectedRescueRecipient = normalizeAddress(expected.rescueRecipient || ZERO);
  if (!isZeroAddress(expectedRescueRecipient)) {
    const liveRescueRecipient = castAddressCall({
      rpcUrl,
      to: maintenanceHubAddr,
      sig: "rescueRecipient()(address)",
    });
    if (liveRescueRecipient !== expectedRescueRecipient) {
      die(
        `existing MaintenanceHub at ${maintenanceHubAddr} does not match current rescueRecipient=${expectedRescueRecipient}. ` +
          `Clear contracts.MaintenanceHub in ${manifestPath} (or fix the manifest) and redeploy it against the current core bundle.`
      );
    }
  }
  const codeHex = castCode({ rpcUrl, to: maintenanceHubAddr }).trim();
  for (const [field, addr] of expected.addresses) {
    if (!codeContainsAddress(codeHex, addr)) {
      die(
        `existing MaintenanceHub at ${maintenanceHubAddr} does not match current ${field}=${addr}. ` +
          `Clear contracts.MaintenanceHub in ${manifestPath} (or fix the manifest) and redeploy it against the current core bundle.`
      );
    }
  }
}

function deriveAddressFromPrivateKey(privateKey) {
  try {
    const addr = runCaptureArgs("cast", ["wallet", "address", "--private-key", privateKey]);
    return normalizeAddress(addr);
  } catch {
    die("failed to derive deployer address from PRIVATE_KEY via cast wallet address");
  }
}

function resolveBootstrapAdmin(manifest, forgeSigner) {
  if (forgeSigner?.signerAddress) {
    return normalizeAddress(forgeSigner.signerAddress);
  }
  return normalizeAddress(manifest?.contracts?.TimelockController?.bootstrapAdmin || ZERO);
}

function resolveForgeSignerConfig(network) {
  const privateKey = process.env.PRIVATE_KEY ?? "";
  if (privateKey) {
    return {
      signerAddress: deriveAddressFromPrivateKey(privateKey),
      forgeArgs: [],
      modeLabel: "private-key",
    };
  }

  const ledgerAddress = normalizeAddress(
    process.env.SIGNER_ADDRESS || process.env.LEDGER_ADDRESS || ZERO
  );
  if (!isZeroAddress(ledgerAddress)) {
    assertSafeShellArg(ledgerAddress, "SIGNER_ADDRESS/LEDGER_ADDRESS");
    const mnemonicIndex = process.env.LEDGER_MNEMONIC_INDEX || "6";
    return {
      signerAddress: ledgerAddress,
      forgeArgs: ["--ledger", "--mnemonic-indexes", mnemonicIndex, "--sender", ledgerAddress],
      modeLabel: "ledger",
    };
  }

  die(`${network} requires PRIVATE_KEY (recommended) or LEDGER_ADDRESS for forge script broadcasting`);
}

function buildForgeBroadcastArgs(scriptTarget, rpcUrl, forgeSigner) {
  return [
    "script",
    scriptTarget,
    "--rpc-url",
    rpcUrl,
    ...forgeSigner.forgeArgs,
    "--broadcast",
    "-vvv",
  ];
}

const NFT_METADATA_ORIGINS = {
  base_mainnet: "https://claimru.sh",
  base_sepolia: "https://staging.claimru.sh",
};

function resolveNftMetadataEnv(network) {
  const origin = NFT_METADATA_ORIGINS[network];
  if (!origin) return {};
  const baseURI = process.env.VE_CLAIM_BASE_URI || `${origin}/api/nft/veclaim/`;
  const contractURI = process.env.VE_CLAIM_CONTRACT_URI || `${origin}/api/nft/veclaim/collection`;
  return { VE_CLAIM_BASE_URI: baseURI, VE_CLAIM_CONTRACT_URI: contractURI };
}

function getRpcChainId(rpcUrl) {
  const out = runCaptureArgs("cast", ["chain-id", "--rpc-url", rpcUrl]);
  const chainId = parseStrictPositiveSafeInteger(out, { defaultValue: null, allowHex: true });
  if (chainId == null) {
    die(`failed to parse RPC chain-id from: ${out}`);
  }
  return chainId;
}

function contractAddr(manifest, key) {
  return normalizeAddress(manifest?.contracts?.[key]?.address || ZERO);
}

function contractMeta(manifest, key) {
  return manifest?.contracts?.[key] ?? {};
}

function resolveManifestAdminSafe(manifest, network) {
  const timelock = contractMeta(manifest, "TimelockController");
  const proposer = normalizeAddress(timelock.proposer || ZERO);
  const executor = normalizeAddress(timelock.executor || ZERO);

  if (!isZeroAddress(proposer) || !isZeroAddress(executor)) {
    if (isZeroAddress(proposer) || isZeroAddress(executor) || proposer !== executor) {
      die(
        "contracts.TimelockController.proposer/executor must both be set to the same canonical Safe " +
          "for deploy_prod mainnet pinning"
      );
    }
    return proposer;
  }

  if (network === "base_mainnet") {
    die(
      "deployments/base_mainnet.json must pin contracts.TimelockController.proposer/executor " +
        "to the canonical governance Safe before deploy"
    );
  }

  return ZERO;
}

function resolveManifestLpWithdrawRecipient(manifest, network) {
  const lpWithdrawRecipient = normalizeAddress(contractMeta(manifest, "GenesisLPVault24M").lpWithdrawRecipient || ZERO);
  if (isZeroAddress(lpWithdrawRecipient) && network === "base_mainnet") {
    die(
      "deployments/base_mainnet.json must pin contracts.GenesisLPVault24M.lpWithdrawRecipient " +
        "before deploy"
    );
  }
  return lpWithdrawRecipient;
}

function resolveManifestRescueRecipient(manifest, network) {
  const rescueRecipient = normalizeAddress(contractMeta(manifest, "MaintenanceHub").rescueRecipient || ZERO);
  if (isZeroAddress(rescueRecipient) && network === "base_mainnet") {
    die(
      "deployments/base_mainnet.json must pin contracts.MaintenanceHub.rescueRecipient " +
        "before deploy"
    );
  }
  return rescueRecipient;
}

function pickPinnedAddress(preferred, fallback = ZERO) {
  const preferredAddr = normalizeAddress(preferred || ZERO);
  if (!isZeroAddress(preferredAddr)) return preferredAddr;
  return normalizeAddress(fallback || ZERO);
}

function setManifestContract(manifest, key, address, startBlock, extra = {}) {
  manifest.contracts[key] ??= { address: ZERO, startBlock: 0 };
  manifest.contracts[key].address = normalizeAddress(address);
  manifest.contracts[key].startBlock = startBlock;
  for (const [extraKey, extraValue] of Object.entries(extra)) {
    manifest.contracts[key][extraKey] = extraValue;
  }
}

function resolveMatchingManifestStartBlock(manifest, key, address) {
  const meta = contractMeta(manifest, key);
  if (normalizeAddress(meta.address || ZERO) !== normalizeAddress(address)) {
    return 0;
  }
  return toStartBlock(meta.startBlock);
}

function findHistoricalCreate(scriptFile, chainId, contractName, expectedAddress = ZERO) {
  const want = normalizeAddress(expectedAddress || ZERO);
  const files = listTimestampedBroadcastFiles(scriptFile, chainId);
  for (let i = files.length - 1; i >= 0; i -= 1) {
    const byName = buildByName(readJson(files[i].path));
    const entries = byName.get(contractName) ?? [];
    for (let j = entries.length - 1; j >= 0; j -= 1) {
      const entry = entries[j];
      if (!isZeroAddress(want) && normalizeAddress(entry.contractAddress) !== want) continue;
      if (entry.blockNumber > 0) return entry;
    }
  }
  return null;
}

function resolveHistoricalCreateStartBlock({
  manifest,
  key,
  address,
  scriptFile,
  chainId,
  contractName,
  label,
}) {
  const existing = resolveMatchingManifestStartBlock(manifest, key, address);
  if (existing > 0) return existing;

  const historical = findHistoricalCreate(scriptFile, chainId, contractName, address);
  if (historical?.blockNumber > 0) return historical.blockNumber;

  die(
    `could not determine ${label} startBlock for ${address}. ` +
      `Provide the exact timestamped ${scriptFile} broadcast file or keep historical broadcast artifacts available.`
  );
}

function txBlockNumber(runJson, tx) {
  const txHash = String(tx?.hash ?? tx?.transactionHash ?? "").toLowerCase();
  const receiptFallback = (runJson.receipts ?? []).find((rec) => {
    const recHash = String(rec?.transactionHash ?? rec?.hash ?? "").toLowerCase();
    return txHash && recHash === txHash;
  });
  return parseBroadcastBlockNumber(tx?.receipt?.blockNumber ?? tx?.blockNumber ?? receiptFallback?.blockNumber);
}

function findCreatePoolBlockNumber({ runJson, factory, weth, claimAddr, stable }) {
  const factoryAddr = normalizeAddress(factory);
  const wethAddr = normalizeAddress(weth);
  const claim = normalizeAddress(claimAddr);
  const stableString = stable ? "true" : "false";

  for (const tx of runJson.transactions ?? []) {
    const to = normalizeAddress(tx?.transaction?.to ?? tx?.contractAddress ?? ZERO);
    const fn = String(tx?.function ?? "");
    const args = Array.isArray(tx?.arguments) ? tx.arguments.map((arg) => String(arg ?? "")) : [];
    if (to !== factoryAddr) continue;
    if (!fn.startsWith("createPool(")) continue;
    if (args.length < 3) continue;

    const arg0 = normalizeAddress(args[0]);
    const arg1 = normalizeAddress(args[1]);
    const arg2 = String(args[2]).trim().toLowerCase();
    const matchesPair =
      (arg0 === wethAddr && arg1 === claim) || (arg0 === claim && arg1 === wethAddr);
    if (!matchesPair || arg2 !== stableString) continue;

    const blockNumber = txBlockNumber(runJson, tx);
    if (blockNumber > 0) return blockNumber;
  }

  return 0;
}

function findFinalizeGenesisBlockNumber({ runJson, launchController }) {
  const launchAddr = normalizeAddress(launchController);
  for (const tx of runJson.transactions ?? []) {
    const to = normalizeAddress(tx?.transaction?.to ?? tx?.contractAddress ?? ZERO);
    const fn = String(tx?.function ?? "");
    if (to !== launchAddr) continue;
    if (fn !== "finalizeGenesis()") continue;
    const blockNumber = txBlockNumber(runJson, tx);
    if (blockNumber > 0) return blockNumber;
  }
  return 0;
}

function resolvePoolStartBlock({
  network,
  poolLive,
  existingStartBlock,
  deployRunJson,
  finalizeRunJson,
  factory,
  weth,
  claimAddr,
  launchController,
}) {
  if (!poolLive) return 0;

  const existing = toStartBlock(existingStartBlock);
  if (network === "base_sepolia" && deployRunJson) {
    const derived = findCreatePoolBlockNumber({
      runJson: deployRunJson,
      factory,
      weth,
      claimAddr,
      stable: false,
    });
    if (derived > 0) return derived;
  }

  if (finalizeRunJson) {
    const derived = findFinalizeGenesisBlockNumber({
      runJson: finalizeRunJson,
      launchController,
    });
    if (derived > 0) return derived;
    die("FinalizeGenesis broadcast file does not contain a finalized finalizeGenesis() transaction");
  }

  if (existing > 0) return existing;

  if (network === "base_mainnet") {
    die(
      "canonical CLAIM/WETH pool has live code but deployments manifest is missing claimWethPool.startBlock. " +
        "Pass --finalize-broadcast-file with the exact FinalizeGenesis.s.sol run-<timestamp>.json to pin the creation block."
    );
  }

  if (network === "base_sepolia") {
    die(
      "canonical CLAIM/WETH pool has live code but deploy_prod could not derive its creation block from the current Deploy.s.sol broadcast. " +
        "Use an exact Deploy.s.sol run-<timestamp>.json from the deployment that created the pool."
    );
  }

  return existing;
}

function assertTimelockRoleGranted({ rpcUrl, timelock, roleGetterSig, roleName, expected }) {
  const role = castCall({ rpcUrl, to: timelock, sig: roleGetterSig }).trim();
  if (!role.startsWith("0x")) {
    die(`failed to read ${roleName} hash from ${timelock}: ${role}`);
  }
  const granted = castBoolCall({
    rpcUrl,
    to: timelock,
    sig: "hasRole(bytes32,address)(bool)",
    args: [role, expected],
  });
  if (!granted) {
    die(`${roleName} is not granted to expected address ${expected} on TimelockController ${timelock}`);
  }
}

function updateDeploymentManifest({
  network,
  rpcUrl,
  manifestPath,
  aerodromeRouter,
  adminSafe,
  lpWithdrawRecipient,
  bootstrapAdmin,
  deployRunJson = null,
  finalizeRunJson = null,
  byName,
  fallbackDeployments = new Map(),
}) {
  const manifest = readJson(manifestPath);
  manifest.contracts ??= {};

  const requiredSingles = [
    ["ClaimToken", "ClaimToken"],
    ["VeClaimNFT", "VeClaimNFT"],
    ["MineCoreQuoter", "MineCoreQuoter"],
    ["ClaimAllHelper", "ClaimAllHelper"],
    ["DelegationHub", "DelegationHub"],
    ["DexAdapter", "DexAdapter"],
    ["LpStakingVault7D", "LpStakingVault7D"],
    ["GenesisLPVault24M", "GenesisLPVault24M"],
    ["LaunchController", "LaunchController"],
    ["TimelockController", "TimelockController"],
  ];

  for (const [contractName, manifestKey] of requiredSingles) {
    const primaryDeployment = pickLast(byName, contractName);
    const fallbackDeployment = fallbackDeployments.get(contractName) || null;
    const d = primaryDeployment || fallbackDeployment || null;
    if (!d) die(`broadcast missing deployment for ${contractName}`);
    if (d.blockNumber <= 0) {
      die(`broadcast missing block number for ${contractName} (startBlock would be 0)`);
    }
    if (isZeroAddress(normalizeAddress(d.contractAddress))) {
      die(`broadcast returned zero address for ${contractName}`);
    }
    setManifestContract(manifest, manifestKey, d.contractAddress, d.blockNumber);
  }

  {
    const genesisVaultAddr = contractAddr(manifest, "GenesisLPVault24M");
    if (!isZeroAddress(genesisVaultAddr)) {
      const liveLpWithdrawRecipient = castAddressCall({
        rpcUrl,
        to: genesisVaultAddr,
        sig: "lpWithdrawRecipient()(address)",
      });
      const expectedLpWithdrawRecipient = pickPinnedAddress(
        lpWithdrawRecipient,
        contractMeta(manifest, "GenesisLPVault24M").lpWithdrawRecipient
      );
      if (!isZeroAddress(expectedLpWithdrawRecipient) && liveLpWithdrawRecipient !== expectedLpWithdrawRecipient) {
        die(
          `GenesisLPVault24M.lpWithdrawRecipient mismatch: expected=${expectedLpWithdrawRecipient}, ` +
            `live=${liveLpWithdrawRecipient}`
        );
      }
      manifest.contracts.GenesisLPVault24M.lpWithdrawRecipient = liveLpWithdrawRecipient;
    }
  }

  const runtimeQuartet = [
    ["MineCore", "MineCore", "MineCoreProxy"],
    ["ShareholderRoyalties", "ShareholderRoyalties", "ShareholderRoyaltiesProxy"],
    ["Furnace", "Furnace", "FurnaceProxy"],
    ["MarketRouter", "MarketRouter", "MarketRouterProxy"],
  ];

  for (const [manifestKey, implementationName, proxyName] of runtimeQuartet) {
    const implementationDeployment = pickLast(byName, implementationName);
    const proxyDeployment = pickLast(byName, proxyName);
    if (!implementationDeployment) die(`broadcast missing deployment for ${implementationName}`);
    if (!proxyDeployment) die(`broadcast missing deployment for ${proxyName}`);
    if (implementationDeployment.blockNumber <= 0) {
      die(`broadcast missing block number for ${implementationName} (startBlock would be 0)`);
    }
    if (proxyDeployment.blockNumber <= 0) {
      die(`broadcast missing block number for ${proxyName} (startBlock would be 0)`);
    }

    const proxyMeta = readProxyMetadata({
      rpcUrl,
      proxy: proxyDeployment.contractAddress,
      label: manifestKey,
    });
    if (normalizeAddress(proxyMeta.implementation) !== normalizeAddress(implementationDeployment.contractAddress)) {
      die(
        `${manifestKey} proxy implementation mismatch: broadcast=${implementationDeployment.contractAddress}, ` +
          `live=${proxyMeta.implementation}`
      );
    }
    requireNonZero(proxyMeta.proxyAdmin, `${manifestKey}.proxyAdmin`);
    if (!hasLiveCode({ rpcUrl, to: proxyMeta.proxyAdmin })) {
      die(`${manifestKey} proxy admin ${proxyMeta.proxyAdmin} has no code`);
    }
    const proxyAdminOwner = castAddressCall({
      rpcUrl,
      to: proxyMeta.proxyAdmin,
      sig: "owner()(address)",
    });

    const extra = {
      implementation: proxyMeta.implementation,
      proxyAdmin: proxyMeta.proxyAdmin,
      proxyAdminOwner,
    };

    // Furnace's impl pins a FurnaceGuardHelper as `address immutable` at construction
    // (src/Furnace.sol: `address payable internal immutable _guardHelper`). The helper
    // is a separate contract created by Deploy.s.sol immediately before the Furnace impl
    // and is not callable as a public surface. Recording its address under
    // contracts.Furnace.guardHelper lets bytecode-parity tooling resolve the immutable
    // slot from the manifest alone.
    //
    // Furnace also self-deploys a FurnaceExtendHelper in its constructor (immutable
    // `_extendHelper`) that holds the extendWithBonus body. Recording that address under
    // contracts.Furnace.extendHelper mirrors the guardHelper pin for parity tooling.
    if (manifestKey === "Furnace") {
      const guardHelperDeployment = pickLast(byName, "FurnaceGuardHelper");
      if (!guardHelperDeployment) {
        die("broadcast missing deployment for FurnaceGuardHelper (required by Furnace impl as `address immutable`)");
      }
      const guardHelperAddress = normalizeAddress(guardHelperDeployment.contractAddress);
      if (isZeroAddress(guardHelperAddress)) {
        die("broadcast returned zero address for FurnaceGuardHelper");
      }
      if (!hasLiveCode({ rpcUrl, to: guardHelperAddress })) {
        die(`FurnaceGuardHelper ${guardHelperAddress} has no code`);
      }
      extra.guardHelper = guardHelperAddress;

      const extendHelperDeployment = pickLast(byName, "FurnaceExtendHelper");
      if (!extendHelperDeployment) {
        die("broadcast missing deployment for FurnaceExtendHelper (required by Furnace impl as `address immutable`)");
      }
      const extendHelperAddress = normalizeAddress(extendHelperDeployment.contractAddress);
      if (isZeroAddress(extendHelperAddress)) {
        die("broadcast returned zero address for FurnaceExtendHelper");
      }
      if (!hasLiveCode({ rpcUrl, to: extendHelperAddress })) {
        die(`FurnaceExtendHelper ${extendHelperAddress} has no code`);
      }
      extra.extendHelper = extendHelperAddress;
    }

    setManifestContract(manifest, manifestKey, proxyDeployment.contractAddress, proxyDeployment.blockNumber, extra);
  }

  const regs = pickLastN(byName, "EntryTokenRegistry", 2);
  if (regs.length < 2) {
    die(`expected 2 EntryTokenRegistry deployments, found ${(byName.get("EntryTokenRegistry") ?? []).length}`);
  }

  if (regs[0].blockNumber <= 0) {
    die("broadcast missing block number for FurnaceEntryTokenRegistry (startBlock would be 0)");
  }
  if (regs[1].blockNumber <= 0) {
    die("broadcast missing block number for MineCoreEntryTokenRegistry (startBlock would be 0)");
  }
  setManifestContract(manifest, "FurnaceEntryTokenRegistry", regs[0].contractAddress, regs[0].blockNumber);
  setManifestContract(manifest, "MineCoreEntryTokenRegistry", regs[1].contractAddress, regs[1].blockNumber);

  const staleMaintenanceHub = normalizeAddress(manifest?.contracts?.MaintenanceHub?.address || ZERO);
  if (!isZeroAddress(staleMaintenanceHub)) {
    console.log(`[deploy_prod] clearing stale MaintenanceHub from deploy-based manifest refresh: ${staleMaintenanceHub}`);
  }
  manifest.contracts.MaintenanceHub = {
    address: ZERO,
    rescueRecipient: normalizeAddress(contractMeta(manifest, "MaintenanceHub").rescueRecipient || ZERO),
    startBlock: 0,
  };

  const staleFurnaceQuoter = normalizeAddress(manifest?.contracts?.FurnaceQuoter?.address || ZERO);
  if (!isZeroAddress(staleFurnaceQuoter)) {
    console.log(`[deploy_prod] clearing stale FurnaceQuoter from deploy-based manifest refresh: ${staleFurnaceQuoter}`);
  }
  manifest.contracts.FurnaceQuoter = { address: ZERO, startBlock: 0 };

  const staleAgentLens = normalizeAddress(manifest?.contracts?.AgentLens?.address || ZERO);
  if (!isZeroAddress(staleAgentLens)) {
    console.log(`[deploy_prod] clearing stale AgentLens from deploy-based manifest refresh: ${staleAgentLens}`);
  }
  manifest.contracts.AgentLens = { address: ZERO, startBlock: 0 };

  const startBlocks = Object.values(manifest.contracts)
    .map((c) => toStartBlock(c?.startBlock))
    .filter((b) => b > 0);
  const earliest = startBlocks.length ? Math.min(...startBlocks) : 0;

  manifest.aerodrome ??= {};
  manifest.aerodrome.router ??= { address: ZERO, startBlock: 0 };
  manifest.aerodrome.router.address = normalizeAddress(aerodromeRouter);
  if (manifest.aerodrome.router.startBlock === 0 && earliest > 0) {
    manifest.aerodrome.router.startBlock = earliest;
  }

  const dexAddr = requireNonZero(manifest.contracts.DexAdapter.address, "contracts.DexAdapter.address");
  const claimAddr = requireNonZero(manifest.contracts.ClaimToken.address, "contracts.ClaimToken.address");

  const weth = castAddressCall({ rpcUrl, to: dexAddr, sig: "weth()(address)" });
  const factory = castAddressCall({ rpcUrl, to: dexAddr, sig: "defaultFactory()(address)" });

  manifest.aerodrome.wrappedNative ??= { address: ZERO, startBlock: 0 };
  manifest.aerodrome.poolFactory ??= { address: ZERO, startBlock: 0 };

  manifest.aerodrome.wrappedNative.address = weth;
  manifest.aerodrome.poolFactory.address = factory;

  if (manifest.aerodrome.wrappedNative.startBlock === 0 && earliest > 0) {
    manifest.aerodrome.wrappedNative.startBlock = earliest;
  }
  if (manifest.aerodrome.poolFactory.startBlock === 0 && earliest > 0) {
    manifest.aerodrome.poolFactory.startBlock = earliest;
  }

  const expectedPool = castAddressCall({
    rpcUrl,
    to: dexAddr,
    sig: "poolFor(address,address,bool,address)(address)",
    args: [weth, claimAddr, "false", factory],
  });

  const poolLive = hasLiveCode({ rpcUrl, to: expectedPool });
  const publishPoolAddress = poolLive || network !== "base_mainnet";
  const poolStartBlock = resolvePoolStartBlock({
    network,
    poolLive,
    existingStartBlock: manifest.aerodrome?.claimWethPool?.startBlock,
    deployRunJson,
    finalizeRunJson,
    factory,
    weth,
    claimAddr,
    launchController: contractAddr(manifest, "LaunchController"),
  });

  manifest.aerodrome.claimWethPool ??= { address: ZERO, startBlock: 0, poolType: "" };
  manifest.aerodrome.lpToken ??= { address: ZERO, startBlock: 0 };

  manifest.aerodrome.claimWethPool.address = publishPoolAddress ? expectedPool : ZERO;
  manifest.aerodrome.lpToken.address = publishPoolAddress ? expectedPool : ZERO;
  if (!poolLive) {
    manifest.aerodrome.claimWethPool.startBlock = 0;
    manifest.aerodrome.lpToken.startBlock = 0;
  } else {
    manifest.aerodrome.claimWethPool.startBlock = poolStartBlock;
    manifest.aerodrome.lpToken.startBlock = poolStartBlock;
  }

  const timelockAddr = contractAddr(manifest, "TimelockController");
  if (!isZeroAddress(timelockAddr)) {
    requireNonZero(adminSafe, "TimelockController.proposer/executor");
    assertTimelockRoleGranted({
      rpcUrl,
      timelock: timelockAddr,
      roleGetterSig: "PROPOSER_ROLE()(bytes32)",
      roleName: "PROPOSER_ROLE",
      expected: adminSafe,
    });
    assertTimelockRoleGranted({
      rpcUrl,
      timelock: timelockAddr,
      roleGetterSig: "CANCELLER_ROLE()(bytes32)",
      roleName: "CANCELLER_ROLE",
      expected: adminSafe,
    });
    assertTimelockRoleGranted({
      rpcUrl,
      timelock: timelockAddr,
      roleGetterSig: "EXECUTOR_ROLE()(bytes32)",
      roleName: "EXECUTOR_ROLE",
      expected: adminSafe,
    });
    if (isZeroAddress(bootstrapAdmin)) {
      die(
        "missing TimelockController.bootstrapAdmin metadata. Set the active broadcast signer " +
          "or pre-populate contracts.TimelockController.bootstrapAdmin in the manifest."
      );
    }
    manifest.contracts.TimelockController.bootstrapAdmin = normalizeAddress(bootstrapAdmin);
    manifest.contracts.TimelockController.proposer = normalizeAddress(adminSafe);
    manifest.contracts.TimelockController.executor = normalizeAddress(adminSafe);
    manifest.contracts.TimelockController.minDelaySeconds = castUintCall({
      rpcUrl,
      to: timelockAddr,
      sig: "getMinDelay()(uint256)",
    });
  }

  manifest.generatedAtUtc = new Date().toISOString();
  writeJson(manifestPath, manifest);

  console.log(`\n[deploy_prod] wrote ${manifestPath}`);
  console.log(`[deploy_prod] network=${network} earliestStartBlock=${earliest}`);
  if (manifest.aerodrome.claimWethPool.startBlock === 0 || manifest.aerodrome.lpToken.startBlock === 0) {
    if (network === "base_mainnet" && !poolLive) {
      console.log(
        "[deploy_prod] note: Base mainnet keeps aerodrome.claimWethPool / aerodrome.lpToken unset until FinalizeGenesis materializes the deterministic pool. " +
          "After finalization, backfill the live address + receipt block and rerun Wire.s.sol so FurnaceEntryTokenRegistry can bind the canonical hop."
      );
    } else {
      console.log(
        "[deploy_prod] note: aerodrome.claimWethPool.startBlock / aerodrome.lpToken.startBlock are 0. " +
          "On Sepolia the pool is auto-created during Deploy.s.sol; use the exact Deploy.s.sol broadcast file if startBlock recovery is needed."
      );
    }
  } else {
    console.log(
      "[deploy_prod] note: canonical WETH/CLAIM pool has live code; startBlock values must match the genesis finalization tx block"
    );
  }
}

function refreshLiveManifestState({
  network,
  rpcUrl,
  manifestPath,
  aerodromeRouter,
  adminSafe,
  lpWithdrawRecipient,
  bootstrapAdmin,
  finalizeRunJson = null,
}) {
  const manifest = readJson(manifestPath);
  manifest.contracts ??= {};

  const dexAddr = requireNonZero(contractAddr(manifest, "DexAdapter"), "contracts.DexAdapter.address");
  const claimAddr = requireNonZero(contractAddr(manifest, "ClaimToken"), "contracts.ClaimToken.address");
  const genesisVaultAddr = requireNonZero(
    contractAddr(manifest, "GenesisLPVault24M"),
    "contracts.GenesisLPVault24M.address"
  );
  const timelockAddr = requireNonZero(
    contractAddr(manifest, "TimelockController"),
    "contracts.TimelockController.address"
  );

  const liveLpWithdrawRecipient = castAddressCall({
    rpcUrl,
    to: genesisVaultAddr,
    sig: "lpWithdrawRecipient()(address)",
  });
  const expectedLpWithdrawRecipient = pickPinnedAddress(
    lpWithdrawRecipient,
    contractMeta(manifest, "GenesisLPVault24M").lpWithdrawRecipient
  );
  if (!isZeroAddress(expectedLpWithdrawRecipient) && liveLpWithdrawRecipient !== expectedLpWithdrawRecipient) {
    die(
      `GenesisLPVault24M.lpWithdrawRecipient mismatch: expected=${expectedLpWithdrawRecipient}, ` +
        `live=${liveLpWithdrawRecipient}`
    );
  }
  manifest.contracts.GenesisLPVault24M.lpWithdrawRecipient = liveLpWithdrawRecipient;

  manifest.aerodrome ??= {};
  manifest.aerodrome.router ??= { address: ZERO, startBlock: 0 };
  manifest.aerodrome.router.address = normalizeAddress(aerodromeRouter);

  const startBlocks = Object.values(manifest.contracts)
    .map((c) => toStartBlock(c?.startBlock))
    .filter((b) => b > 0);
  const earliest = startBlocks.length ? Math.min(...startBlocks) : 0;
  if (manifest.aerodrome.router.startBlock === 0 && earliest > 0) {
    manifest.aerodrome.router.startBlock = earliest;
  }

  const weth = castAddressCall({ rpcUrl, to: dexAddr, sig: "weth()(address)" });
  const factory = castAddressCall({ rpcUrl, to: dexAddr, sig: "defaultFactory()(address)" });
  manifest.aerodrome.wrappedNative ??= { address: ZERO, startBlock: 0 };
  manifest.aerodrome.poolFactory ??= { address: ZERO, startBlock: 0 };
  manifest.aerodrome.wrappedNative.address = weth;
  manifest.aerodrome.poolFactory.address = factory;
  if (manifest.aerodrome.wrappedNative.startBlock === 0 && earliest > 0) {
    manifest.aerodrome.wrappedNative.startBlock = earliest;
  }
  if (manifest.aerodrome.poolFactory.startBlock === 0 && earliest > 0) {
    manifest.aerodrome.poolFactory.startBlock = earliest;
  }

  const expectedPool = castAddressCall({
    rpcUrl,
    to: dexAddr,
    sig: "poolFor(address,address,bool,address)(address)",
    args: [weth, claimAddr, "false", factory],
  });
  const poolLive = hasLiveCode({ rpcUrl, to: expectedPool });
  const publishPoolAddress = poolLive || network !== "base_mainnet";
  const poolStartBlock = resolvePoolStartBlock({
    network,
    poolLive,
    existingStartBlock: manifest.aerodrome?.claimWethPool?.startBlock,
    deployRunJson: null,
    finalizeRunJson,
    factory,
    weth,
    claimAddr,
    launchController: contractAddr(manifest, "LaunchController"),
  });
  manifest.aerodrome.claimWethPool ??= { address: ZERO, startBlock: 0, poolType: "" };
  manifest.aerodrome.lpToken ??= { address: ZERO, startBlock: 0 };
  manifest.aerodrome.claimWethPool.address = publishPoolAddress ? expectedPool : ZERO;
  manifest.aerodrome.lpToken.address = publishPoolAddress ? expectedPool : ZERO;
  manifest.aerodrome.claimWethPool.startBlock = poolLive ? poolStartBlock : 0;
  manifest.aerodrome.lpToken.startBlock = poolLive ? poolStartBlock : 0;

  requireNonZero(adminSafe, "TimelockController.proposer/executor");
  assertTimelockRoleGranted({
    rpcUrl,
    timelock: timelockAddr,
    roleGetterSig: "PROPOSER_ROLE()(bytes32)",
    roleName: "PROPOSER_ROLE",
    expected: adminSafe,
  });
  assertTimelockRoleGranted({
    rpcUrl,
    timelock: timelockAddr,
    roleGetterSig: "CANCELLER_ROLE()(bytes32)",
    roleName: "CANCELLER_ROLE",
    expected: adminSafe,
  });
  assertTimelockRoleGranted({
    rpcUrl,
    timelock: timelockAddr,
    roleGetterSig: "EXECUTOR_ROLE()(bytes32)",
    roleName: "EXECUTOR_ROLE",
    expected: adminSafe,
  });
  if (isZeroAddress(bootstrapAdmin)) {
    die("missing TimelockController.bootstrapAdmin metadata for manifest refresh");
  }
  manifest.contracts.TimelockController.bootstrapAdmin = normalizeAddress(bootstrapAdmin);
  manifest.contracts.TimelockController.proposer = normalizeAddress(adminSafe);
  manifest.contracts.TimelockController.executor = normalizeAddress(adminSafe);
  manifest.contracts.TimelockController.minDelaySeconds = castUintCall({
    rpcUrl,
    to: timelockAddr,
    sig: "getMinDelay()(uint256)",
  });

  // Refresh proxyAdminOwner for all 4 runtime quartet proxies from live chain state.
  // After FreezeAndBurn, these will be address(0) (burned). Before that, they point to
  // the timelock or deployer. Reading live ensures the manifest never drifts from on-chain.
  const runtimeQuartetKeys = ["MineCore", "Furnace", "MarketRouter", "ShareholderRoyalties"];
  for (const key of runtimeQuartetKeys) {
    const meta = manifest.contracts?.[key];
    if (!meta || isZeroAddress(meta.address)) continue;
    const proxyAdmin = meta.proxyAdmin;
    if (!proxyAdmin || isZeroAddress(proxyAdmin)) continue;
    if (!hasLiveCode({ rpcUrl, to: proxyAdmin })) {
      console.log(`[deploy_prod] WARNING: ${key} proxyAdmin ${proxyAdmin} has no code — skipping owner refresh`);
      continue;
    }
    const liveOwner = castAddressCall({ rpcUrl, to: proxyAdmin, sig: "owner()(address)" });
    const prev = normalizeAddress(meta.proxyAdminOwner || ZERO);
    if (liveOwner !== prev) {
      console.log(`[deploy_prod] ${key}.proxyAdminOwner: ${prev} → ${liveOwner}`);
    }
    meta.proxyAdminOwner = liveOwner;
  }

  manifest.generatedAtUtc = new Date().toISOString();
  writeJson(manifestPath, manifest);
  console.log(`\n[deploy_prod] refreshed live-derived metadata in ${manifestPath}`);
}

function refreshWireDerivedManifestState({ rpcUrl, manifestPath, chainId, allowMissingFurnaceQuoter = false }) {
  const manifest = readJson(manifestPath);
  manifest.contracts ??= {};
  let touched = false;

  const genesisVaultAddr = contractAddr(manifest, "GenesisLPVault24M");
  if (!isZeroAddress(genesisVaultAddr)) {
    const liveLpWithdrawRecipient = castAddressCall({
      rpcUrl,
      to: genesisVaultAddr,
      sig: "lpWithdrawRecipient()(address)",
    });
    const expectedLpWithdrawRecipient = normalizeAddress(
      contractMeta(manifest, "GenesisLPVault24M").lpWithdrawRecipient || ZERO
    );
    if (!isZeroAddress(expectedLpWithdrawRecipient) && liveLpWithdrawRecipient !== expectedLpWithdrawRecipient) {
      die(
        `GenesisLPVault24M.lpWithdrawRecipient mismatch: expected=${expectedLpWithdrawRecipient}, ` +
          `live=${liveLpWithdrawRecipient}`
      );
    }
    manifest.contracts.GenesisLPVault24M.lpWithdrawRecipient = liveLpWithdrawRecipient;
    touched = true;
  }

  const maintenanceHubAddr = contractAddr(manifest, "MaintenanceHub");
  if (!isZeroAddress(maintenanceHubAddr)) {
    if (!hasLiveCode({ rpcUrl, to: maintenanceHubAddr })) {
      die(`manifest MaintenanceHub address ${maintenanceHubAddr} has no code; fix deployments manifest before continuing`);
    }
    const liveRescueRecipient = castAddressCall({
      rpcUrl,
      to: maintenanceHubAddr,
      sig: "rescueRecipient()(address)",
    });
    const expectedRescueRecipient = normalizeAddress(contractMeta(manifest, "MaintenanceHub").rescueRecipient || ZERO);
    if (!isZeroAddress(expectedRescueRecipient) && liveRescueRecipient !== expectedRescueRecipient) {
      die(
        `MaintenanceHub.rescueRecipient mismatch: expected=${expectedRescueRecipient}, live=${liveRescueRecipient}`
      );
    }
    manifest.contracts.MaintenanceHub.rescueRecipient = liveRescueRecipient;
    touched = true;
  }

  const furnaceAddr = contractAddr(manifest, "Furnace");
  if (!isZeroAddress(furnaceAddr)) {
    const liveFurnaceQuoter = castAddressCall({
      rpcUrl,
      to: furnaceAddr,
      sig: "furnaceQuoter()(address)",
    });
    if (isZeroAddress(liveFurnaceQuoter)) {
      if (allowMissingFurnaceQuoter) {
        manifest.contracts.FurnaceQuoter = { address: ZERO, startBlock: 0 };
        if (touched) {
          manifest.generatedAtUtc = new Date().toISOString();
          writeJson(manifestPath, manifest);
          console.log(`\n[deploy_prod] refreshed wire-derived helper metadata in ${manifestPath}`);
        }
        return;
      }
      die("Furnace.furnaceQuoter() is unset after Wire.s.sol; canonical manifest would remain incomplete");
    }
    if (!hasLiveCode({ rpcUrl, to: liveFurnaceQuoter })) {
      die(`Furnace.furnaceQuoter=${liveFurnaceQuoter} has no code`);
    }
    const priorQuoter = normalizeAddress(manifest?.contracts?.FurnaceQuoter?.address || ZERO);
    if (!isZeroAddress(priorQuoter) && priorQuoter !== liveFurnaceQuoter) {
      die(
        `FurnaceQuoter address change: manifest has ${priorQuoter} but live chain returns ${liveFurnaceQuoter}. ` +
          `If intentional, clear manifest FurnaceQuoter first, then re-run.`
      );
    }
    const startBlock = resolveHistoricalCreateStartBlock({
      manifest,
      key: "FurnaceQuoter",
      address: liveFurnaceQuoter,
      scriptFile: "Wire.s.sol",
      chainId,
      contractName: "FurnaceQuoter",
      label: "FurnaceQuoter",
    });
    setManifestContract(manifest, "FurnaceQuoter", liveFurnaceQuoter, startBlock);
    touched = true;
  }

  if (touched) {
    manifest.generatedAtUtc = new Date().toISOString();
    writeJson(manifestPath, manifest);
    console.log(`\n[deploy_prod] refreshed wire-derived helper metadata in ${manifestPath}`);
  }
}

function updateMaintenanceHubManifest({ manifestPath, maintenanceHub }) {
  const manifest = readJson(manifestPath);
  manifest.contracts ??= {};
  manifest.contracts.MaintenanceHub ??= { address: ZERO, rescueRecipient: ZERO, startBlock: 0 };
  manifest.contracts.MaintenanceHub.address = maintenanceHub.contractAddress;
  manifest.contracts.MaintenanceHub.startBlock = maintenanceHub.blockNumber;
  manifest.generatedAtUtc = new Date().toISOString();
  writeJson(manifestPath, manifest);
  console.log(`\n[deploy_prod] updated ${manifestPath} with MaintenanceHub=${maintenanceHub.contractAddress}`);
}

function preflightExistingMaintenanceHubOrDie({ network, rpcUrl, manifestPath }) {
  const manifest = readJson(manifestPath);
  const maintenanceHubAddr = contractAddr(manifest, "MaintenanceHub");
  if (isZeroAddress(maintenanceHubAddr)) return false;

  const market = requireNonZero(contractAddr(manifest, "MarketRouter"), "contracts.MarketRouter.address");
  const furnace = requireNonZero(contractAddr(manifest, "Furnace"), "contracts.Furnace.address");
  const ve = requireNonZero(contractAddr(manifest, "VeClaimNFT"), "contracts.VeClaimNFT.address");
  const royalties = requireNonZero(
    contractAddr(manifest, "ShareholderRoyalties"),
    "contracts.ShareholderRoyalties.address"
  );
  const weth = requireNonZero(normalizeAddress(manifest?.aerodrome?.wrappedNative?.address), "aerodrome.wrappedNative.address");
  const rescueRecipient = resolveManifestRescueRecipient(manifest, network);

  if (!hasLiveCode({ rpcUrl, to: maintenanceHubAddr })) {
    die(`manifest MaintenanceHub address ${maintenanceHubAddr} has no code; fix deployments manifest before continuing`);
  }

  assertMaintenanceHubRuntimeMatches({
    rpcUrl,
    maintenanceHubAddr,
    manifestPath,
    expected: {
      rescueRecipient,
      addresses: [
        ["marketRouter", market],
        ["furnace", furnace],
        ["ve", ve],
        ["royalties", royalties],
        ["weth", weth],
      ],
    },
  });
  console.log(`[deploy_prod] preflight: existing MaintenanceHub ${maintenanceHubAddr} matches the current canonical roots.`);
  return true;
}

function syncGeneratedArtifacts() {
  runArgs("bash", ["scripts/sync_deployments_all.sh", "--write"]);
  runArgs("python3", ["scripts/sync_docs_deployments.py", "--write"]);
}

function assertAgentLensMatches({ rpcUrl, agentLensAddr, manifestPath, manifest }) {
  const expected = [
    ["claimToken", contractAddr(manifest, "ClaimToken")],
    ["veClaimNFT", contractAddr(manifest, "VeClaimNFT")],
    ["mineCore", contractAddr(manifest, "MineCore")],
    ["shareholderRoyalties", contractAddr(manifest, "ShareholderRoyalties")],
    ["furnace", contractAddr(manifest, "Furnace")],
    ["marketRouter", contractAddr(manifest, "MarketRouter")],
    ["lpStakingVault7D", contractAddr(manifest, "LpStakingVault7D")],
    ["dexAdapter", contractAddr(manifest, "DexAdapter")],
    ["furnaceEntryTokenRegistry", contractAddr(manifest, "FurnaceEntryTokenRegistry")],
    ["mineCoreEntryTokenRegistry", contractAddr(manifest, "MineCoreEntryTokenRegistry")],
    ["delegationHub", contractAddr(manifest, "DelegationHub")],
    ["claimAllHelper", contractAddr(manifest, "ClaimAllHelper")],
    ["maintenanceHub", contractAddr(manifest, "MaintenanceHub")],
    ["launchController", contractAddr(manifest, "LaunchController")],
    ["genesisLPVault24M", contractAddr(manifest, "GenesisLPVault24M")],
  ];

  for (const [field, expectedAddr] of expected) {
    const want = normalizeAddress(expectedAddr || ZERO);
    const got = castAddressCall({
      rpcUrl,
      to: agentLensAddr,
      sig: `${field}()(address)`,
    });
    if (got !== want) {
      die(
        `existing AgentLens at ${agentLensAddr} does not match current ${field}=${want}. ` +
          `Clear contracts.AgentLens in ${manifestPath} (or fix the manifest) and redeploy it against the current canonical bundle.`
      );
    }
  }
}

function deployMaintenanceHubIfNeeded({ network, rpcUrl, manifestPath, chainId, noSync, forgeSigner }) {
  const manifest = readJson(manifestPath);
  const maintenanceHubAddr = contractAddr(manifest, "MaintenanceHub");
  const market = requireNonZero(contractAddr(manifest, "MarketRouter"), "contracts.MarketRouter.address");
  const furnace = requireNonZero(contractAddr(manifest, "Furnace"), "contracts.Furnace.address");
  const ve = requireNonZero(contractAddr(manifest, "VeClaimNFT"), "contracts.VeClaimNFT.address");
  const royalties = requireNonZero(
    contractAddr(manifest, "ShareholderRoyalties"),
    "contracts.ShareholderRoyalties.address"
  );
  const weth = requireNonZero(normalizeAddress(manifest?.aerodrome?.wrappedNative?.address), "aerodrome.wrappedNative.address");
  const manifestRescueRecipient = resolveManifestRescueRecipient(manifest, network);
  const envRescueRecipient = process.env.RESCUE_RECIPIENT ? normalizeAddress(process.env.RESCUE_RECIPIENT) : ZERO;
  if (
    !isZeroAddress(manifestRescueRecipient) &&
    !isZeroAddress(envRescueRecipient) &&
    manifestRescueRecipient !== envRescueRecipient
  ) {
    die(
      `RESCUE_RECIPIENT env (${envRescueRecipient}) does not match pinned manifest rescue recipient (${manifestRescueRecipient})`
    );
  }
  const rescueRecipient = !isZeroAddress(envRescueRecipient)
    ? envRescueRecipient
    : (!isZeroAddress(manifestRescueRecipient) ? manifestRescueRecipient : normalizeAddress(forgeSigner.signerAddress));

  if (!isZeroAddress(maintenanceHubAddr)) {
    if (hasLiveCode({ rpcUrl, to: maintenanceHubAddr })) {
      assertMaintenanceHubRuntimeMatches({
        rpcUrl,
        maintenanceHubAddr,
        manifestPath,
        expected: {
          rescueRecipient,
          addresses: [
            ["marketRouter", market],
            ["furnace", furnace],
            ["ve", ve],
            ["royalties", royalties],
            ["weth", weth],
          ],
        },
      });
      console.log(
        `[deploy_prod] MaintenanceHub already deployed at ${maintenanceHubAddr} and matches the current canonical roots; skipping.`
      );
      return false;
    }
    die(`manifest MaintenanceHub address ${maintenanceHubAddr} has no code; fix deployments manifest before continuing`);
  }

  const maintenanceHubStartedAtMs = Date.now();
  runArgs(
    "forge",
    buildForgeBroadcastArgs("script/DeployMaintenanceHub.s.sol:DeployMaintenanceHub", rpcUrl, forgeSigner),
    {
      env: {
        MARKET_ROUTER: market,
        FURNACE: furnace,
        VECLAIM_NFT: ve,
        SHAREHOLDER_ROYALTIES: royalties,
        WETH: weth,
        RESCUE_RECIPIENT: rescueRecipient,
      },
    }
  );

  const broadcastPath = resolveFreshBroadcastFile(
    "DeployMaintenanceHub.s.sol",
    chainId,
    maintenanceHubStartedAtMs,
    "DeployMaintenanceHub.s.sol"
  );
  const runJson = readJson(broadcastPath);
  const byName = buildByName(runJson);
  const maintenanceHub = pickLast(byName, "MaintenanceHub");
  if (!maintenanceHub) {
    die("broadcast missing deployment for MaintenanceHub");
  }
  if (maintenanceHub.blockNumber <= 0) {
    die("broadcast missing block number for MaintenanceHub (startBlock would be 0)");
  }

  updateMaintenanceHubManifest({ manifestPath, maintenanceHub });
  if (!noSync) {
    syncGeneratedArtifacts();
  }
  return true;
}

function deployAgentLensIfNeeded({ rpcUrl, manifestPath, chainId, noSync, forgeSigner, force }) {
  const manifest = readJson(manifestPath);
  const agentLensAddr = contractAddr(manifest, "AgentLens");
  const claim = requireNonZero(contractAddr(manifest, "ClaimToken"), "contracts.ClaimToken.address");
  const ve = requireNonZero(contractAddr(manifest, "VeClaimNFT"), "contracts.VeClaimNFT.address");
  const mine = requireNonZero(contractAddr(manifest, "MineCore"), "contracts.MineCore.address");
  const royalties = requireNonZero(
    contractAddr(manifest, "ShareholderRoyalties"),
    "contracts.ShareholderRoyalties.address"
  );
  const furnace = requireNonZero(contractAddr(manifest, "Furnace"), "contracts.Furnace.address");
  const market = requireNonZero(contractAddr(manifest, "MarketRouter"), "contracts.MarketRouter.address");
  const lpVault = requireNonZero(contractAddr(manifest, "LpStakingVault7D"), "contracts.LpStakingVault7D.address");
  const dex = requireNonZero(contractAddr(manifest, "DexAdapter"), "contracts.DexAdapter.address");
  const regFurn = requireNonZero(
    contractAddr(manifest, "FurnaceEntryTokenRegistry"),
    "contracts.FurnaceEntryTokenRegistry.address"
  );
  const regMine = requireNonZero(
    contractAddr(manifest, "MineCoreEntryTokenRegistry"),
    "contracts.MineCoreEntryTokenRegistry.address"
  );
  const delegation = requireNonZero(contractAddr(manifest, "DelegationHub"), "contracts.DelegationHub.address");
  const helper = requireNonZero(contractAddr(manifest, "ClaimAllHelper"), "contracts.ClaimAllHelper.address");
  const maintenanceHub = requireNonZero(contractAddr(manifest, "MaintenanceHub"), "contracts.MaintenanceHub.address");
  const launch = requireNonZero(contractAddr(manifest, "LaunchController"), "contracts.LaunchController.address");
  const genesisVault = requireNonZero(
    contractAddr(manifest, "GenesisLPVault24M"),
    "contracts.GenesisLPVault24M.address"
  );

  if (!isZeroAddress(agentLensAddr)) {
    if (hasLiveCode({ rpcUrl, to: agentLensAddr })) {
      assertAgentLensMatches({ rpcUrl, agentLensAddr, manifestPath, manifest });
      if (force) {
        console.log(
          `[deploy_prod] AgentLens already deployed at ${agentLensAddr} and matches the current canonical bundle, ` +
            `but --force-agent-lens is set; redeploying against the local artifact bytecode.`
        );
      } else {
        console.log(`[deploy_prod] AgentLens already deployed at ${agentLensAddr} and matches the current canonical bundle; skipping.`);
        return false;
      }
    } else {
      die(`manifest AgentLens address ${agentLensAddr} has no code; fix deployments manifest before continuing`);
    }
  }

  const agentLensStartedAtMs = Date.now();
  runArgs(
    "forge",
    buildForgeBroadcastArgs("script/DeployAgentLens.s.sol:DeployAgentLens", rpcUrl, forgeSigner),
    {
      env: {
        CLAIM_TOKEN: claim,
        VECLAIM_NFT: ve,
        MINE_CORE: mine,
        SHAREHOLDER_ROYALTIES: royalties,
        FURNACE: furnace,
        MARKET_ROUTER: market,
        LP_STAKING_VAULT_7D: lpVault,
        DEX_ADAPTER: dex,
        FURNACE_ENTRY_TOKEN_REGISTRY: regFurn,
        MINE_CORE_ENTRY_TOKEN_REGISTRY: regMine,
        DELEGATION_HUB: delegation,
        CLAIM_ALL_HELPER: helper,
        MAINTENANCE_HUB: maintenanceHub,
        LAUNCH_CONTROLLER: launch,
        GENESIS_LP_VAULT_24M: genesisVault,
      },
    }
  );

  const broadcastPath = resolveFreshBroadcastFile(
    "DeployAgentLens.s.sol",
    chainId,
    agentLensStartedAtMs,
    "DeployAgentLens.s.sol"
  );
  const runJson = readJson(broadcastPath);
  const byName = buildByName(runJson);
  const agentLens = pickLast(byName, "AgentLens");
  if (!agentLens) {
    die("broadcast missing deployment for AgentLens");
  }
  if (agentLens.blockNumber <= 0) {
    die("broadcast missing block number for AgentLens (startBlock would be 0)");
  }

  setManifestContract(manifest, "AgentLens", agentLens.contractAddress, agentLens.blockNumber);
  manifest.generatedAtUtc = new Date().toISOString();
  writeJson(manifestPath, manifest);
  console.log(`\n[deploy_prod] updated ${manifestPath} with AgentLens=${agentLens.contractAddress}`);

  if (!noSync) {
    syncGeneratedArtifacts();
  }
  return true;
}

function main() {
  if (hasFlag("--help") || hasFlag("-h")) {
    help();
    process.exit(0);
  }

  const network = getArg("--network", process.env.NETWORK);
  const rpcUrl = getArg("--rpc-url", process.env.RPC_URL);
  if (!network) die("missing --network (base_mainnet | base_sepolia)");
  if (!SUPPORTED_NETWORKS.has(network)) {
    die(`unsupported --network ${network}. This wrapper is intentionally limited to base_mainnet and base_sepolia.`);
  }
  if (!rpcUrl) die("missing --rpc-url (or RPC_URL env)");
  assertSafeShellArg(rpcUrl, "--rpc-url");
  assertSafeShellArg(network, "--network");

  let doDeploy = hasFlag("--deploy");
  if (hasFlag("--no-deploy")) doDeploy = false;
  const doDeployAgentLens = hasFlag("--deploy-agent-lens");
  const forceAgentLens = hasFlag("--force-agent-lens");
  if (forceAgentLens && !doDeployAgentLens) {
    die("--force-agent-lens requires --deploy-agent-lens (it modifies the AgentLens-only deploy path's skip-if-already-deployed branch).");
  }
  const doRefreshManifestFromBroadcast = hasFlag("--refresh-manifest-from-broadcast");
  const deployBroadcastFileArg = getArg("--deploy-broadcast-file");
  const timelockBroadcastFileArg = getArg("--timelock-broadcast-file");
  const mineCoreQuoterBroadcastFileArg = getArg("--minecorequoter-broadcast-file");
  const finalizeBroadcastFileArg = getArg("--finalize-broadcast-file");
  const doRefreshLiveState = hasFlag("--refresh-live-state") || Boolean(finalizeBroadcastFileArg);
  const doWire = hasFlag("--wire");
  const doVerify = hasFlag("--verify");
  const noSync = hasFlag("--no-sync");

  const manifestPath = path.join("deployments", `${network}.json`);
  if (!fs.existsSync(manifestPath)) die(`missing manifest file: ${manifestPath}`);

  const manifest = readJson(manifestPath);
  const chainId = parseStrictPositiveSafeInteger(manifest.chainId, {
    defaultValue: null,
    allowHex: true,
  });
  if (chainId == null) die(`manifest missing/invalid chainId: ${manifestPath}`);

  const rpcChainId = getRpcChainId(rpcUrl);
  if (rpcChainId !== chainId) {
    die(
      `RPC chain-id mismatch: manifest/network expects ${chainId} but ${rpcUrl} reports ${rpcChainId}. Refusing to deploy or wire against the wrong chain.`
    );
  }
  console.log(`[deploy_prod] RPC chainId confirmed: ${rpcChainId}`);
  const forgeSigner = resolveForgeSignerConfig(network);
  console.log(`[deploy_prod] forge signer mode: ${forgeSigner.modeLabel} (${forgeSigner.signerAddress})`);
  const bootstrapAdmin = resolveBootstrapAdmin(manifest, forgeSigner);

  const pinnedRouter = normalizeAddress(manifest?.aerodrome?.router?.address);
  const envRouter = process.env.AERODROME_ROUTER ? normalizeAddress(process.env.AERODROME_ROUTER) : "";
  if (envRouter && !isZeroAddress(pinnedRouter) && envRouter !== pinnedRouter) {
    die(`AERODROME_ROUTER env (${envRouter}) does not match pinned manifest router (${pinnedRouter})`);
  }
  const aerodromeRouter = normalizeAddress(envRouter || pinnedRouter);
  requireNonZero(aerodromeRouter, "AERODROME_ROUTER (env or deployments/*)");
  if ((doDeploy || doRefreshManifestFromBroadcast || doRefreshLiveState) && !hasLiveCode({ rpcUrl, to: aerodromeRouter })) {
    die(`AERODROME_ROUTER ${aerodromeRouter} has no code. Verify the address is correct for chain ${chainId}.`);
  }

  const pinnedAdminSafe = resolveManifestAdminSafe(manifest, network);
  const envAdminSafe = process.env.ADMIN_SAFE ? normalizeAddress(process.env.ADMIN_SAFE) : ZERO;
  if (!isZeroAddress(envAdminSafe) && !isZeroAddress(pinnedAdminSafe) && envAdminSafe !== pinnedAdminSafe) {
    die(`ADMIN_SAFE env (${envAdminSafe}) does not match pinned manifest Safe (${pinnedAdminSafe})`);
  }
  const adminSafe = normalizeAddress(!isZeroAddress(envAdminSafe) ? envAdminSafe : pinnedAdminSafe);
  if (
    (doDeploy || doRefreshManifestFromBroadcast || doRefreshLiveState || doWire) &&
    network === "base_mainnet" &&
    !isZeroAddress(adminSafe) &&
    !hasLiveCode({ rpcUrl, to: adminSafe })
  ) {
    die(`ADMIN_SAFE ${adminSafe} has no code on Base mainnet. Activate/deploy the Safe before continuing.`);
  }

  const pinnedLpWithdrawRecipient = resolveManifestLpWithdrawRecipient(manifest, network);
  const envLpWithdrawRecipient = process.env.LP_WITHDRAW_RECIPIENT
    ? normalizeAddress(process.env.LP_WITHDRAW_RECIPIENT)
    : ZERO;
  if (
    !isZeroAddress(envLpWithdrawRecipient) &&
    !isZeroAddress(pinnedLpWithdrawRecipient) &&
    envLpWithdrawRecipient !== pinnedLpWithdrawRecipient
  ) {
    die(
      `LP_WITHDRAW_RECIPIENT env (${envLpWithdrawRecipient}) does not match pinned manifest recipient ` +
        `(${pinnedLpWithdrawRecipient})`
    );
  }
  const lpWithdrawRecipient = normalizeAddress(
    !isZeroAddress(envLpWithdrawRecipient) ? envLpWithdrawRecipient : pinnedLpWithdrawRecipient
  );

  // Validate that the pinned Chainlink ETH/USD feed is a live AggregatorV3 on mainnet.
  const pinnedEthUsdFeed = normalizeAddress(manifest?.chainlink?.ethUsdFeed?.address);
  if (
    (doDeploy || doRefreshLiveState) &&
    network === "base_mainnet" &&
    !isZeroAddress(pinnedEthUsdFeed)
  ) {
    if (!hasLiveCode({ rpcUrl, to: pinnedEthUsdFeed })) {
      die(`Chainlink ETH/USD feed ${pinnedEthUsdFeed} has no code on Base mainnet. Verify the address against official Chainlink docs.`);
    }
    try {
      const answer = castUintCall({ rpcUrl, to: pinnedEthUsdFeed, sig: "latestAnswer()(int256)" });
      if (answer <= 0) {
        die(`Chainlink ETH/USD feed ${pinnedEthUsdFeed} returned non-positive answer (${answer}). Feed may be misconfigured.`);
      }
      console.log(`[deploy_prod] preflight: Chainlink ETH/USD feed ${pinnedEthUsdFeed} is live (answer=${answer}).`);
    } catch (e) {
      die(`Chainlink ETH/USD feed ${pinnedEthUsdFeed} failed latestAnswer() call. Verify the address is a valid AggregatorV3 on Base mainnet.`);
    }
  }

  let finalizeRunJson = null;
  if (finalizeBroadcastFileArg) {
    finalizeRunJson = readJson(assertExactBroadcastFile(finalizeBroadcastFileArg, "FinalizeGenesis.s.sol"));
  }

  if (doDeploy && doWire) {
    const initialOwner = process.env.INITIAL_OWNER ? normalizeAddress(process.env.INITIAL_OWNER) : ZERO;
    if (!isZeroAddress(initialOwner)) {
      if (initialOwner !== forgeSigner.signerAddress) {
        die(
          `INITIAL_OWNER=${initialOwner} differs from broadcast signer=${forgeSigner.signerAddress}. The one-command --deploy --wire path is only safe when INITIAL_OWNER is unset or equals the selected broadcaster; use the manual split-key flow instead.`
        );
      }
    }
  }

  let deployRunJson = null;
  let timelockRunJson = null;
  let timelockAddress = process.env.TIMELOCK_ADDRESS
    ? normalizeAddress(process.env.TIMELOCK_ADDRESS)
    : ZERO;
  if (doDeploy) {
    if (isZeroAddress(lpWithdrawRecipient)) {
      die(
        "missing LP_WITHDRAW_RECIPIENT. Set it via env or pin contracts.GenesisLPVault24M.lpWithdrawRecipient " +
          "in the deployments manifest before broadcasting."
      );
    }
    requireNonZero(adminSafe, "ADMIN_SAFE (env or deployments/*)");

    console.log("[deploy_prod] Running compile + contract-size preflight before broadcasting...");
    runArgs("forge", ["build"]);
    runArgs("python3", ["scripts/check_contract_sizes.py", "--fail"]);

    // Phase 1: deploy TimelockController in its own broadcast log to bypass the
    // forge-broadcast trace-decoder bug at the LaunchController -> TimelockController
    // CREATE adjacency. See script/DeployTimelock.s.sol for the long-form rationale.
    if (isZeroAddress(timelockAddress)) {
      console.log("[deploy_prod] Phase 1/2: deploying TimelockController standalone via DeployTimelock.s.sol...");
      const timelockStartedAtMs = Date.now();
      runArgs(
        "forge",
        buildForgeBroadcastArgs("script/DeployTimelock.s.sol:DeployTimelock", rpcUrl, forgeSigner),
        {
          env: {
            ADMIN_SAFE: adminSafe,
          },
        }
      );
      const timelockBroadcastPath = resolveFreshBroadcastFile(
        "DeployTimelock.s.sol",
        chainId,
        timelockStartedAtMs,
        "DeployTimelock.s.sol"
      );
      timelockRunJson = readJson(timelockBroadcastPath);
      const timelockByName = buildByName(timelockRunJson);
      const timelockEntry = pickLast(timelockByName, "TimelockController");
      if (!timelockEntry) {
        die("DeployTimelock.s.sol broadcast missing TimelockController CREATE");
      }
      if (timelockEntry.blockNumber <= 0) {
        die("DeployTimelock.s.sol broadcast missing block number for TimelockController");
      }
      timelockAddress = normalizeAddress(timelockEntry.contractAddress);
      console.log(
        `[deploy_prod] Phase 1/2 complete: TimelockController=${timelockAddress} (block ${timelockEntry.blockNumber})`
      );
    } else {
      console.log(
        `[deploy_prod] Phase 1/2 skipped: TIMELOCK_ADDRESS already set in env (${timelockAddress}); will reuse.`
      );
    }
    requireNonZero(timelockAddress, "TIMELOCK_ADDRESS (post-Phase 1)");

    console.log("[deploy_prod] Phase 2/2: running main Deploy.s.sol against pre-deployed Timelock...");
    const deployStartedAtMs = Date.now();
    runArgs("forge", buildForgeBroadcastArgs("script/Deploy.s.sol:Deploy", rpcUrl, forgeSigner), {
      env: {
        AERODROME_ROUTER: aerodromeRouter,
        ADMIN_SAFE: adminSafe,
        LP_WITHDRAW_RECIPIENT: lpWithdrawRecipient,
        TIMELOCK_ADDRESS: timelockAddress,
      },
    });
    deployRunJson = readJson(resolveFreshBroadcastFile("Deploy.s.sol", chainId, deployStartedAtMs, "Deploy.s.sol"));
  }

  if (doDeploy || doRefreshManifestFromBroadcast) {
    requireNonZero(adminSafe, "ADMIN_SAFE (env or deployments/*)");
    if (!deployRunJson) {
      if (!doRefreshManifestFromBroadcast) {
        die("internal error: missing Deploy.s.sol broadcast data for manifest refresh");
      }
      if (!deployBroadcastFileArg) {
        die(
          "--refresh-manifest-from-broadcast without --deploy requires --deploy-broadcast-file " +
            "pointing at an exact run-<timestamp>.json artifact"
        );
      }
      deployRunJson = readJson(assertExactBroadcastFile(deployBroadcastFileArg, "Deploy.s.sol"));
    }

    const byName = buildByName(deployRunJson);
    const fallbackDeployments = new Map();

    // TimelockController is deployed by script/DeployTimelock.s.sol in its own
    // broadcast log (see Phase 1 above). Source it from there for manifest pinning.
    if (!timelockRunJson && timelockBroadcastFileArg) {
      timelockRunJson = readJson(
        assertExactBroadcastFile(timelockBroadcastFileArg, "DeployTimelock.s.sol")
      );
    }
    if (timelockRunJson) {
      const timelockByName = buildByName(timelockRunJson);
      const timelockEntry = pickLast(timelockByName, "TimelockController");
      if (timelockEntry) {
        fallbackDeployments.set("TimelockController", timelockEntry);
      }
    } else if (doRefreshManifestFromBroadcast && !doDeploy) {
      die(
        "--refresh-manifest-from-broadcast without --deploy requires --timelock-broadcast-file " +
          "pointing at the matching DeployTimelock.s.sol run-<timestamp>.json artifact"
      );
    }

    // Backwards-compatible repair path:
    // - current Deploy.s.sol broadcasts include MineCoreQuoter directly
    // - older deploys may have used the standalone DeployMineCoreQuoter.s.sol helper
    if (mineCoreQuoterBroadcastFileArg) {
      const quoterBroadcast = buildByName(
        readJson(assertExactBroadcastFile(mineCoreQuoterBroadcastFileArg, "DeployMineCoreQuoter.s.sol"))
      );
      const mineCoreQuoter = pickLast(quoterBroadcast, "MineCoreQuoter");
      if (mineCoreQuoter) {
        fallbackDeployments.set("MineCoreQuoter", mineCoreQuoter);
      }
    }

    updateDeploymentManifest({
      network,
      rpcUrl,
      manifestPath,
      aerodromeRouter,
      adminSafe,
      lpWithdrawRecipient,
      bootstrapAdmin,
      deployRunJson,
      finalizeRunJson,
      byName,
      fallbackDeployments,
    });

    if (!noSync) {
      syncGeneratedArtifacts();
    }
  } else if (doRefreshLiveState) {
    requireNonZero(adminSafe, "ADMIN_SAFE (env or deployments/*)");
    refreshLiveManifestState({
      network,
      rpcUrl,
      manifestPath,
      aerodromeRouter,
      adminSafe,
      lpWithdrawRecipient,
      bootstrapAdmin,
      finalizeRunJson,
    });

    refreshWireDerivedManifestState({
      rpcUrl,
      manifestPath,
      chainId,
      allowMissingFurnaceQuoter: true,
    });

    if (!noSync) {
      syncGeneratedArtifacts();
    }
  } else {
    console.log(
      "[deploy_prod] using existing deployments manifest; skipping broadcast-derived refresh (pass --refresh-manifest-from-broadcast after a manual Deploy.s.sol run)"
    );
  }

  if (doWire) {
    preflightExistingMaintenanceHubOrDie({ network, rpcUrl, manifestPath });
    const nftMetadataEnv = resolveNftMetadataEnv(network);
    runArgs("forge", buildForgeBroadcastArgs("script/Wire.s.sol:Wire", rpcUrl, forgeSigner), { env: nftMetadataEnv });

    const maintenanceHubDeployed = deployMaintenanceHubIfNeeded({
      network,
      rpcUrl,
      manifestPath,
      chainId,
      noSync: true,
      forgeSigner,
    });

    if (maintenanceHubDeployed) {
      console.log("[deploy_prod] Re-running Wire.s.sol after MaintenanceHub deployment...");
      runArgs("forge", buildForgeBroadcastArgs("script/Wire.s.sol:Wire", rpcUrl, forgeSigner), { env: nftMetadataEnv });
    }

    refreshWireDerivedManifestState({
      rpcUrl,
      manifestPath,
      chainId,
    });

    deployAgentLensIfNeeded({
      rpcUrl,
      manifestPath,
      chainId,
      noSync: true,
      forgeSigner,
    });

    refreshWireDerivedManifestState({
      rpcUrl,
      manifestPath,
      chainId,
    });

    if (!noSync) {
      syncGeneratedArtifacts();
    }
  }

  if (doDeployAgentLens) {
    deployAgentLensIfNeeded({
      rpcUrl,
      manifestPath,
      chainId,
      noSync: true,
      forgeSigner,
      force: forceAgentLens,
    });

    if (!noSync) {
      syncGeneratedArtifacts();
    }
  }

  if (doVerify) {
    runArgs("python3", ["scripts/verify_deployment.py", "--network", network, "--rpc-url", rpcUrl]);
  }

  console.log("\n[deploy_prod] done");
}

main();
