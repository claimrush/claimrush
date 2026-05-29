import 'dotenv/config';
import { createPublicClient, http, webSocket } from 'viem';
import {
  loadDeploymentManifest,
  parseEventStreamEnv,
  startClaimRushEventStream,
  stringifyJson,
} from '../src/index.js';

type CliOpts = {
  rpcUrl: string;
  wsUrl?: string;
  chain: string;
  abiNetwork: any;
  contractsCsv?: string;
  eventsCsv?: string;
  fromBlock?: bigint | 'manifest';
  format: 'jsonl' | 'pretty';
  poll: boolean;
  pollingInterval?: number;
  includeBlockTimestamp: boolean;
  subgraphUrl?: string;
  backfill: boolean;
  backfillLimit?: number;
};

function deriveWsUrl(rpcUrl: string): string | undefined {
  if (rpcUrl.startsWith('https://')) return `wss://${rpcUrl.slice('https://'.length)}`;
  if (rpcUrl.startsWith('http://')) return `ws://${rpcUrl.slice('http://'.length)}`;
  return undefined;
}

function parseArgs(argv: string[], env: NodeJS.ProcessEnv): CliOpts {
  const get = (key: string): string | undefined => {
    const pref = `--${key}=`;
    const hit = argv.find((a) => a.startsWith(pref));
    if (hit) return hit.slice(pref.length);
    const idx = argv.findIndex((a) => a === `--${key}`);
    if (idx >= 0) return argv[idx + 1];
    return undefined;
  };

  const help = argv.includes('--help') || argv.includes('-h');
  if (help) {
    console.log(
      `\nClaimRush event streamer\n\nUsage\n  npm -C agents/sdk run example:events -- [options]\n\nOptions\n  --rpc-url <url>          HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)\n  --ws-url <url>           WebSocket RPC (default: WS_URL or derived from rpc-url)\n  --chain <name>           Manifest chain (default: CLAIMRUSH_CHAIN or local)\n  --abi-network <name>     ABI folder (default: ABI_NETWORK or base_sepolia)\n  --contracts <csv>        Contract keys (default: CONTRACTS env or core set)\n  --events <csv>           Event names (default: EVENTS env or core set; use '*' for all)\n  --from-block <n|manifest> Start block (default: head; 'manifest' uses manifest startBlock)\n  --format <jsonl|pretty>  Output format (default: jsonl)\n  --poll                   Force HTTP polling (no WS subscriptions)\n  --polling-interval <ms>  Polling interval when --poll is used (default: 2000)\n  --no-timestamps          Do not fetch block timestamps\n\nExamples\n  EVENTS=Takeover,FurnaceEnter npm -C agents/sdk run example:events\n  CONTRACTS=MineCore EVENTS=Takeover --from-block 0 npm -C agents/sdk run example:events\n  --ws-url ws://127.0.0.1:8545 --format pretty npm -C agents/sdk run example:events\n`,
    );
    process.exit(0);
  }

  const rpcUrl = get('rpc-url') ?? env.RPC_URL ?? 'http://127.0.0.1:8545';
  const wsUrl = get('ws-url') ?? env.WS_URL ?? deriveWsUrl(rpcUrl);
  const chain = get('chain') ?? env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (get('abi-network') ?? env.ABI_NETWORK ?? 'base_sepolia') as any;

  const contractsCsv = get('contracts');
  const eventsCsv = get('events');

  const fromBlockRaw = get('from-block') ?? env.FROM_BLOCK;
  const fromBlock: bigint | 'manifest' | undefined =
    fromBlockRaw === undefined
      ? undefined
      : fromBlockRaw === 'manifest'
        ? 'manifest'
        : BigInt(fromBlockRaw);

  const format =
    ((get('format') ?? env.FORMAT ?? 'jsonl') as any) === 'pretty' ? 'pretty' : 'jsonl';
  const poll = argv.includes('--poll') || env.POLL === '1';
  const pollingIntervalRaw = get('polling-interval') ?? env.POLLING_INTERVAL;
  const pollingInterval = pollingIntervalRaw ? Number(pollingIntervalRaw) : undefined;

  const includeBlockTimestamp = !(argv.includes('--no-timestamps') || env.NO_TIMESTAMPS === '1');

  const subgraphUrl = get('subgraph-url') ?? env.SUBGRAPH_URL;
  const backfill = argv.includes('--backfill') || env.BACKFILL === '1';
  const backfillLimitRaw = get('backfill-limit') ?? env.BACKFILL_LIMIT;
  const backfillLimit = backfillLimitRaw ? Number(backfillLimitRaw) : undefined;

  return {
    rpcUrl,
    wsUrl,
    chain,
    abiNetwork,
    contractsCsv,
    eventsCsv,
    fromBlock,
    format,
    poll,
    pollingInterval,
    includeBlockTimestamp,
    subgraphUrl,
    backfill,
    backfillLimit,
  };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);
  const manifest = loadDeploymentManifest({ chain: cli.chain });

  // Prefer WS if available and not explicitly polling.
  const publicClient =
    cli.wsUrl && !cli.poll
      ? createPublicClient({ transport: webSocket(cli.wsUrl) })
      : createPublicClient({ transport: http(cli.rpcUrl) });

  const { contracts, events } = parseEventStreamEnv(process.env);

  const finalContracts = cli.contractsCsv
    ? cli.contractsCsv
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
    : contracts;
  const finalEvents = cli.eventsCsv
    ? cli.eventsCsv
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
    : events;

  const handle = await startClaimRushEventStream({
    publicClient,
    manifest,
    abiNetwork: cli.abiNetwork,
    contracts: finalContracts,
    events: finalEvents,
    fromBlock: cli.fromBlock,
    poll: cli.poll,
    pollingInterval: cli.pollingInterval,
    includeBlockTimestamp: cli.includeBlockTimestamp,
    subgraphUrl: cli.subgraphUrl,
    backfillFromSubgraph: cli.backfill,
    backfillLimit: cli.backfillLimit,
    onEvent: (ev) => {
      if (cli.format === 'pretty') {
        const ts = ev.blockTimestamp ? Number(ev.blockTimestamp) : undefined;
        const iso = ts ? new Date(ts * 1000).toISOString() : '';
        console.log(
          `${ev.contract}.${ev.event} block=${ev.blockNumber.toString()} tx=${ev.transactionHash.slice(0, 10)}... ${iso}`,
        );
        console.log(stringifyJson(ev.args, { pretty: true }));
      } else {
        console.log(stringifyJson(ev));
      }
    },
    onError: (err) => {
      console.error(err);
    },
  });

  console.error(
    stringifyJson(
      {
        status: 'streaming',
        transport: cli.wsUrl && !cli.poll ? 'websocket' : 'http',
        wsUrl: cli.wsUrl && !cli.poll ? cli.wsUrl : undefined,
        rpcUrl: cli.rpcUrl,
        chain: cli.chain,
        fromBlock: cli.fromBlock ?? 'head',
      },
      { pretty: true },
    ),
  );

  const stop = () => {
    try {
      handle.stop();
    } finally {
      process.exit(0);
    }
  };

  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
