import {
  createClaimRushClients,
  loadDeploymentManifest,
  startClaimRushEventStream,
  stringifyJson,
} from '@claimrush/agent-sdk';

import { makeFlagBag, helpRequested } from '../util/args.js';
import { resolveNetwork, isChainName } from '../safety/networks.js';

const HELP = `claimrush monitor - tail events / achievements (read-only)

USAGE
  claimrush monitor [--chain local|base_sepolia|base] [--rpc-url URL]
                    [--contracts MineCore,Furnace,...] [--events Takeover,...]
                    [--from-block N] [--limit N] [--poll]

DEFAULT
  - Streams MineCore + Furnace + Royalties core events on the current chain.
  - Each event is printed as a single JSON line (JSONL) for downstream ingest.

NOTES
  - This is a thin wrapper around startClaimRushEventStream from the SDK.
    See agents/sdk/README.md and CRAL ids 30-32 for full filter semantics.
  - Use --poll on HTTP-only RPCs (no eth_subscribe).
`;

export async function runMonitor(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }

  const chainArg = f.get('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  if (!isChainName(chainArg)) {
    console.error(`[claimrush monitor] invalid --chain '${chainArg}'`);
    return 64;
  }
  const net = resolveNetwork({ chain: chainArg, rpcUrl: f.get('rpc-url') });

  const manifest = loadDeploymentManifest({ chain: net.manifestStem });
  const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl });

  const contractsCsv = f.get('contracts');
  const eventsCsv = f.get('events');
  const fromBlock = f.get('from-block') ? BigInt(f.get('from-block') as string) : undefined;
  const limit = f.get('limit') ? Number(f.get('limit')) : undefined;
  const poll = f.has('poll');

  let stopHandle: { stop: () => void } | null = null;

  const stop = (): void => {
    try {
      stopHandle?.stop();
    } catch {
      /* ignore */
    }
    process.exit(0);
  };

  let count = 0;
  const onEvent = (ev: unknown): void => {
    console.log(stringifyJson(ev));
    count += 1;
    if (typeof limit === 'number' && limit > 0 && count >= limit) stop();
  };

  const opts: Record<string, unknown> = {
    publicClient,
    manifest,
    abiNetwork: net.abiNetwork,
    onEvent,
  };
  if (contractsCsv) opts.contracts = contractsCsv.split(',').map((s) => s.trim());
  if (eventsCsv) opts.events = eventsCsv.split(',').map((s) => s.trim());
  if (fromBlock !== undefined) opts.fromBlock = fromBlock;
  if (poll) opts.poll = true;

  stopHandle = await startClaimRushEventStream(opts as any);

  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);

  await new Promise<void>(() => {
    /* idle until SIGINT or limit reached */
  });
  return 0;
}
