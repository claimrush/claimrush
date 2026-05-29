import 'dotenv/config';

import { createClaimRushClients, loadDeploymentManifest, stringifyJson } from '../src/index.js';
import {
  SubgraphClient,
  getSubgraphMeta,
  getSubgraphProtocol,
  normalizeSubgraphAddress,
} from '../src/subgraph.js';

function parseArgs(argv: string[]): {
  maxLagBlocks: bigint;
  pretty: boolean;
} {
  let maxLagBlocks = 200n;
  let pretty = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--max-lag-blocks') {
      const v = argv[i + 1];
      if (!v) throw new Error('--max-lag-blocks requires a value');
      maxLagBlocks = BigInt(v);
      i++;
      continue;
    }
    if (a === '--pretty') {
      pretty = true;
      continue;
    }
  }

  return { maxLagBlocks, pretty };
}

function lower(s: string | null | undefined): string | null {
  return s ? s.toLowerCase() : null;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const subgraphUrl = process.env.SUBGRAPH_URL;
  if (!subgraphUrl) throw new Error('SUBGRAPH_URL is required (GraphQL endpoint)');

  const chain = process.env.CLAIMRUSH_CHAIN ?? 'local';
  const manifest = loadDeploymentManifest({ chain });

  const { publicClient } = createClaimRushClients({ rpcUrl });
  const sg = new SubgraphClient({ url: subgraphUrl });

  const [rpcHead, meta, protocol] = await Promise.all([
    publicClient.getBlockNumber(),
    getSubgraphMeta(sg).catch(() => null),
    getSubgraphProtocol(sg).catch(() => null),
  ]);

  const subgraphBlock = meta ? BigInt(meta.blockNumber) : null;
  const lagBlocks = subgraphBlock !== null ? rpcHead - subgraphBlock : null;

  const addrChecks: Array<{
    key: string;
    expected?: string;
    got?: string | null;
    ok: boolean;
  }> = [];

  const p = protocol;
  if (p) {
    const mappings: Array<[string, string | null | undefined]> = [
      ['ClaimToken', p.claimToken],
      ['VeClaimNFT', p.veClaimNft],
      ['MineCore', p.mineCore],
      ['ShareholderRoyalties', p.shareholderRoyalties],
      ['Furnace', p.furnace],
      ['MarketRouter', p.marketRouter],
      ['FurnaceEntryTokenRegistry', p.furnaceEntryTokenRegistry],
      ['MineCoreEntryTokenRegistry', p.mineCoreEntryTokenRegistry],
      // subgraph uses lpStakingVault (not 7D suffix)
      ['LpStakingVault7D', p.lpStakingVault],
      ['LaunchController', p.launchController],
      ['GenesisLPVault24M', p.genesisLpVault24m],
    ];

    for (const [manifestKey, protoAddr] of mappings) {
      const expected = (manifest.contracts as any)?.[manifestKey]?.address as string | undefined;
      if (!expected) continue;
      const got = protoAddr ?? null;
      const ok = lower(expected) === lower(got);
      addrChecks.push({ key: manifestKey, expected, got, ok });
    }
  }

  const coreKeys = new Set([
    'ClaimToken',
    'VeClaimNFT',
    'MineCore',
    'ShareholderRoyalties',
    'Furnace',
    'MarketRouter',
  ]);
  const coreOk = addrChecks.filter((c) => coreKeys.has(c.key)).every((c) => c.ok);

  const warnings: string[] = [];

  if (!protocol)
    warnings.push('protocol entity missing (subgraph not indexed yet or wrong endpoint)');

  if (protocol) {
    if (protocol.chainId !== manifest.chainId) {
      warnings.push(`chainId mismatch: manifest=${manifest.chainId} subgraph=${protocol.chainId}`);
    }

    // Optional address sanity checks (helps catch Bytes that aren't 20-byte addresses)
    // Note: protocol.dexAdapter is intentionally excluded from address parity here.
    // The current v1.0.0 event-driven subgraph does not emit DexAdapter wiring directly,
    // so parity is limited to fields that are discoverable from indexed receipts.
    for (const [label, addr] of [
      ['claimToken', protocol.claimToken],
      ['mineCore', protocol.mineCore],
      ['furnace', protocol.furnace],
    ] as const) {
      if (!normalizeSubgraphAddress(addr))
        warnings.push(`protocol.${label} is not a valid address: ${addr}`);
    }
  }

  if (lagBlocks !== null && lagBlocks > args.maxLagBlocks) {
    warnings.push(
      `subgraph is behind head by ${lagBlocks.toString()} blocks (max ${args.maxLagBlocks.toString()})`,
    );
  }

  const ok =
    protocol !== null &&
    (subgraphBlock === null ? true : lagBlocks !== null && lagBlocks <= args.maxLagBlocks) &&
    coreOk;

  const result = {
    ok,
    rpc: {
      rpcUrl,
      headBlock: rpcHead.toString(),
    },
    subgraph: {
      subgraphUrl,
      metaBlock: subgraphBlock?.toString() ?? null,
      lagBlocks: lagBlocks?.toString() ?? null,
    },
    protocol: protocol
      ? {
          chainId: protocol.chainId,
          version: protocol.version,
          takeoversPaused: protocol.takeoversPaused,
          lockingPaused: protocol.lockingPaused,
          tradingPaused: protocol.tradingPaused,
        }
      : null,
    addressParity: {
      coreOk,
      checks: addrChecks,
    },
    warnings,
  };

  console.log(stringifyJson(result, { pretty: args.pretty }));

  if (!ok) process.exit(2);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
