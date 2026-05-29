import 'dotenv/config';
import { runClaimRushHarness } from '../src/index.js';

type CliOpts = {
  rpcUrl: string;
  chain: string;
  abiNetwork: any;
  scenario: 'all' | 'furnace' | 'takeovers' | 'claim' | 'delegated';
  outdir?: string;
  actorCount?: number;
  ethIn?: string;
  lockDurationDays?: number;
  takeoverCount?: number;

  // delegated scenario knobs
  delegatedPerms?: string;
  delegatedExpirySeconds?: number;
  delegatedSigDeadlineSeconds?: number;
  delegatedRunTakeover?: boolean;

  strict: boolean;
};

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
      `\nClaimRush agent harness (local simulation)\n\nUsage\n  npm -C agents/sdk run example:harness -- [options]\n\nOptions\n  --rpc-url <url>            HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)\n  --chain <name>             Manifest chain (default: CLAIMRUSH_CHAIN or local)\n  --abi-network <name>       ABI folder (default: ABI_NETWORK or base_sepolia)\n  --scenario <name>          all|furnace|takeovers|claim|delegated (default: all)\n  --outdir <path>            Output dir (default: agents/sdk/out/harness-<ts>)\n  --actors <n>               Number of actors (default: 3)\n  --eth-in <eth>             Furnace entry ETH (default: 1000)\n  --lock-duration-days <n>   ve lock duration in days (default: 30)\n  --takeovers <n>            Takeover count (default: 2)\n\n  # scenario=delegated\n  --delegated-perms <mask>              DelegationHub perms (hex or decimal)\n  --delegated-expiry-seconds <n>        Session lifetime in seconds (default: 3600)\n  --delegated-sig-deadline-seconds <n>  Signature deadline in seconds (default: 600)\n  --delegated-run-takeover <1|0>        Enable takeover step (default: 1)\n\n  --strict / --no-strict     Fail on any step error (default: true on local, false otherwise)\n\nEnvironment\n  MNEMONIC or LOCAL_MNEMONIC           Actor derivation seed (defaults to Anvil test mnemonic)\n  PRIVATE_KEYS                         Comma-separated private keys (overrides mnemonic)\n\n  # Delegated scenario (scenario=delegated)\n  DELEGATED_SESSION_EXPIRY_SECONDS     Session lifetime (default: 3600)\n  DELEGATED_SIG_DEADLINE_SECONDS       Signature deadline (default: 600)\n  DELEGATED_PERMS                      Permission bitmask (hex or decimal)\n  DELEGATED_ETH_IN                     Furnace entry ETH paid by delegate (default: 1000)\n  DELEGATED_RUN_TAKEOVER               1|0 (default: 1)\n\nExamples\n  npm -C agents/sdk run example:harness\n  RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:harness -- --takeovers 5\n  npm -C agents/sdk run example:harness -- --scenario furnace --eth-in 500\n`,
    );
    process.exit(0);
  }

  const rpcUrl = get('rpc-url') ?? env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = get('chain') ?? env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (get('abi-network') ?? env.ABI_NETWORK ?? 'base_sepolia') as any;
  const scenario = (get('scenario') ?? env.SCENARIO ?? 'all') as any;

  const outdir = get('outdir') ?? env.OUTDIR;
  const actorCount = get('actors')
    ? Number(get('actors'))
    : env.ACTORS
      ? Number(env.ACTORS)
      : undefined;
  const ethIn = get('eth-in') ?? env.ETH_IN;
  const lockDurationDays = get('lock-duration-days')
    ? Number(get('lock-duration-days'))
    : env.LOCK_DURATION_DAYS
      ? Number(env.LOCK_DURATION_DAYS)
      : undefined;
  const takeoverCount = get('takeovers')
    ? Number(get('takeovers'))
    : env.TAKEOVER_COUNT
      ? Number(env.TAKEOVER_COUNT)
      : undefined;

  // Delegated scenario tuning (scenario=delegated)
  const delegatedPerms = get('delegated-perms') ?? env.DELEGATED_PERMS;
  const delegatedExpirySeconds = get('delegated-expiry-seconds')
    ? Number(get('delegated-expiry-seconds'))
    : env.DELEGATED_SESSION_EXPIRY_SECONDS
      ? Number(env.DELEGATED_SESSION_EXPIRY_SECONDS)
      : undefined;
  const delegatedSigDeadlineSeconds = get('delegated-sig-deadline-seconds')
    ? Number(get('delegated-sig-deadline-seconds'))
    : env.DELEGATED_SIG_DEADLINE_SECONDS
      ? Number(env.DELEGATED_SIG_DEADLINE_SECONDS)
      : undefined;
  const delegatedRunTakeover = get('delegated-run-takeover')
    ? get('delegated-run-takeover') !== '0'
    : env.DELEGATED_RUN_TAKEOVER
      ? env.DELEGATED_RUN_TAKEOVER !== '0'
      : undefined;

  const strict = argv.includes('--no-strict')
    ? false
    : argv.includes('--strict')
      ? true
      : env.STRICT !== undefined
        ? env.STRICT === '1'
        : chain === 'local';

  return {
    rpcUrl,
    chain,
    abiNetwork,
    scenario,
    outdir,
    actorCount,
    ethIn,
    lockDurationDays,
    takeoverCount,
    delegatedPerms,
    delegatedExpirySeconds,
    delegatedSigDeadlineSeconds,
    delegatedRunTakeover,
    strict,
  };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  const res = await runClaimRushHarness({
    rpcUrl: cli.rpcUrl,
    chain: cli.chain,
    abiNetwork: cli.abiNetwork,
    scenario: cli.scenario,
    outdir: cli.outdir,
    actorCount: cli.actorCount,
    ethIn: cli.ethIn,
    lockDurationDays: cli.lockDurationDays,
    takeoverCount: cli.takeoverCount,
    delegatedPerms: cli.delegatedPerms,
    delegatedExpirySeconds: cli.delegatedExpirySeconds,
    delegatedSigDeadlineSeconds: cli.delegatedSigDeadlineSeconds,
    delegatedRunTakeover: cli.delegatedRunTakeover,
    strict: cli.strict,
  });

  console.log(
    JSON.stringify(
      {
        ok: res.ok,
        chain: res.chain,
        chainId: res.chainId,
        outdir: res.outdir,
        actors: res.actors,
        steps: res.steps.map((s) => ({ name: s.name, status: s.status })),
      },
      null,
      2,
    ),
  );

  if (!res.ok) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
