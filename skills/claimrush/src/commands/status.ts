import type { Address } from 'viem';
import { formatEther, isAddress } from 'viem';

import {
  createClaimRushClients,
  getGameStateSnapshot,
  loadDeploymentManifest,
  stringifySnapshot,
} from '@claimrush/agent-sdk';

import { makeFlagBag, helpRequested } from '../util/args.js';
import { resolveNetwork, isChainName } from '../safety/networks.js';
import { jsonStringify } from '../safety/cral.js';
import { rpcHeadProbe } from '../safety/preflight.js';

const HELP = `claimrush status - read game state (no writes)

USAGE
  claimrush status [--chain local|base_sepolia|base] [--rpc-url URL]
                   [--user 0x... | --acting-for 0x...] [--full] [--pretty]

Outputs (default: condensed)
  - chainId, blockNumber, head age (RPC lag probe)
  - mineCore: currentTakeoverPrice, currentKing, currentReignStartTime, takeoversPaused
  - furnace: reserveCLAIM, bonusBudget, virtualDepth (when present)
  - royalties: ethPerVe, pendingShareholderETH (slice if --user given)
  - veCLAIM (slice if --user given)

Use --full to print the full SDK snapshot via stringifySnapshot.
`;

export async function runStatus(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }

  const chainArg = f.get('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  if (!isChainName(chainArg)) {
    console.error(`[claimrush status] invalid --chain '${chainArg}'`);
    return 64;
  }
  const net = resolveNetwork({ chain: chainArg, rpcUrl: f.get('rpc-url') });

  const userInput = f.get('user') ?? f.get('acting-for') ?? process.env.USER_ADDRESS;
  let user: Address | undefined;
  if (userInput) {
    if (!isAddress(userInput)) {
      console.error(`[claimrush status] --user not a valid address: ${userInput}`);
      return 64;
    }
    user = userInput as Address;
  }

  const manifest = loadDeploymentManifest({ chain: net.manifestStem });
  const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl });
  const head = await rpcHeadProbe(publicClient);

  const snap = await getGameStateSnapshot({
    publicClient,
    manifest,
    abiNetwork: net.abiNetwork,
    user,
  });

  const pretty = f.has('pretty');
  const full = f.has('full');

  if (full) {
    console.log(stringifySnapshot(snap, { pretty }));
    return 0;
  }

  // Condensed view that's nice for chat output.
  const m = (snap as any).global?.mineCore ?? (snap as any).mineCore;
  const fur = (snap as any).global?.furnace ?? (snap as any).furnace;
  const roy = (snap as any).global?.royalties ?? (snap as any).royalties;
  const userSlice = (snap as any).user;

  const condensed = {
    chain: net.chain,
    chainId: (snap as any).meta?.chainId ?? null,
    rpcHead: {
      blockNumber: head.blockNumber.toString(),
      timestamp: head.timestamp.toString(),
      ageSeconds: head.ageSeconds.toString(),
    },
    mineCore: m
      ? {
          currentTakeoverPrice: bigishToString(m.currentTakeoverPrice),
          currentTakeoverPriceEth: tryFormatEther(m.currentTakeoverPrice),
          currentKing: m.currentKing,
          currentReignStartTime: bigishToString(m.currentReignStartTime),
          takeoversPaused: m.takeoversPaused,
          referencePrice: bigishToString(m.referencePrice),
        }
      : null,
    furnace: fur
      ? {
          reserveClaim: bigishToString(fur.reserveClaim ?? fur.reserveCLAIM),
          bonusBudget: bigishToString(fur.bonusBudget),
          virtualDepth: bigishToString(fur.virtualDepth),
        }
      : null,
    royalties: roy
      ? {
          ethPerVe: bigishToString(roy.ethPerVe),
          totalShares: bigishToString(roy.totalShares ?? roy.totalVe),
        }
      : null,
    user: userSlice
      ? {
          address: userSlice.address,
          ethBalance: bigishToString(userSlice.ethBalance),
          ethBalanceEth: tryFormatEther(userSlice.ethBalance),
          claimBalance: bigishToString(userSlice.claimBalance),
          pendingShareholderEth: bigishToString(userSlice.pendingShareholderEth),
          pendingShareholderEthEth: tryFormatEther(userSlice.pendingShareholderEth),
          kingBalance: bigishToString(userSlice.kingBalance),
          refundBalance: bigishToString(userSlice.refundBalance),
          veSummary: userSlice.veSummary ?? null,
        }
      : null,
  };

  console.log(jsonStringify(condensed, pretty));
  return 0;
}

function bigishToString(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v === 'bigint') return v.toString();
  if (typeof v === 'number') return String(v);
  if (typeof v === 'string') return v;
  return null;
}

function tryFormatEther(v: unknown): string | null {
  if (typeof v !== 'bigint') return null;
  try {
    return formatEther(v);
  } catch {
    return null;
  }
}
