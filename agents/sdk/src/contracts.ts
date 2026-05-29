import { getContract, type Address, type PublicClient, type WalletClient } from 'viem';
import type { AbiNetwork } from './abis.js';
import { loadAbi } from './abis.js';
import type { DeploymentManifest } from './manifest.js';

export type GetClaimRushContractsParams = {
  manifest: DeploymentManifest;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  /** Which ABI folder to read from. Default: base_sepolia. */
  abiNetwork?: AbiNetwork;
  /** Optional explicit repo root. */
  repoRoot?: string;
};

const ABI_NAME_OVERRIDES: Record<string, string> = {
  FurnaceEntryTokenRegistry: 'EntryTokenRegistry',
  MineCoreEntryTokenRegistry: 'EntryTokenRegistry',
};

function resolveAbiName(contractName: string): string {
  return ABI_NAME_OVERRIDES[contractName] ?? contractName;
}

export type ClaimRushContracts = Record<string, ReturnType<typeof getContract>>;

/**
 * Satellite contracts whose addresses are discovered on-chain rather than from
 * the deployment manifest.  Each entry maps a logical contract name to the
 * parent contract that exposes the address getter and the view function name.
 */
const DERIVED_CONTRACTS: ReadonlyArray<{
  name: string;
  parentContract: string;
  addressGetter: string;
}> = [{ name: 'FurnaceQuoter', parentContract: 'Furnace', addressGetter: 'furnaceQuoter' }];

/**
 * Creates viem contract clients for every contract in the deployment manifest
 * **plus** satellite contracts whose addresses are discovered on-chain (e.g.
 * `FurnaceQuoter` via `Furnace.furnaceQuoter()`).
 *
 * Notes
 * - Contracts are exposed by their manifest keys (e.g. `MineCore`, `Furnace`, ...).
 * - ABI file names generally match contract names, except where overridden (EntryTokenRegistry).
 * - Derived contracts are resolved in parallel via a single multicall-style batch.
 */
export async function getClaimRushContracts(
  params: GetClaimRushContractsParams,
): Promise<ClaimRushContracts> {
  const out: ClaimRushContracts = {};

  for (const [contractName, ref] of Object.entries(params.manifest.contracts)) {
    const abiName = resolveAbiName(contractName);
    const abi = loadAbi({
      contractName: abiName,
      abiNetwork: params.abiNetwork,
      repoRoot: params.repoRoot,
    });

    out[contractName] = getContract({
      address: ref.address as Address,
      abi,
      client: {
        public: params.publicClient,
        wallet: params.walletClient,
      },
    });
  }

  // Resolve satellite contracts whose addresses live on-chain.
  const derivedWork = DERIVED_CONTRACTS.filter((d) => d.parentContract in out);

  const addresses = await Promise.all(
    derivedWork.map((d) => {
      const parent = out[d.parentContract]!;
      return params.publicClient.readContract({
        address: (parent as any).address as Address,
        abi: (parent as any).abi,
        functionName: d.addressGetter,
      }) as Promise<Address>;
    }),
  );

  for (let i = 0; i < derivedWork.length; i++) {
    const d = derivedWork[i]!;
    const abi = loadAbi({
      contractName: d.name,
      abiNetwork: params.abiNetwork,
      repoRoot: params.repoRoot,
    });
    out[d.name] = getContract({
      address: addresses[i]!,
      abi,
      client: {
        public: params.publicClient,
        wallet: params.walletClient,
      },
    });
  }

  return out;
}
