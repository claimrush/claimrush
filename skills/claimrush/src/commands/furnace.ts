import { runLock } from './lock.js';
import { runStatus } from './status.js';
import { helpRequested } from '../util/args.js';

const HELP = `claimrush furnace - chat-friendly aliases for the Furnace

USAGE
  claimrush furnace lock <ETH> [--duration-days 30] [--auto-max] [--slippage-bps 50] [--execute]
  claimrush furnace status [--user 0x... | --acting-for 0x...]

EXAMPLES
  # Dry-run a 0.05 ETH Furnace entry (always run this first):
  claimrush furnace lock 0.05

  # Same, with execution (the standard mainnet flow then also needs --i-understand):
  claimrush furnace lock 0.05 --execute --chain base --i-understand

NOTES
  - 'furnace lock <ETH>' is a thin alias that rewrites to 'claimrush lock --eth <ETH>'.
  - All CRAL guards (caps, slippage, deadlines, mainnet --i-understand gate, dry-run
    default) apply identically to the underlying 'lock' verb.
  - For CLAIM or token entries, use 'claimrush lock --claim N' / 'claimrush lock --token 0x...' directly.
`;

export async function runFurnace(argv: string[]): Promise<number> {
  if (helpRequested(argv) || argv.length === 0) {
    console.log(HELP);
    return argv.length === 0 ? 64 : 0;
  }

  const sub = String(argv[0]);
  const rest = argv.slice(1);

  if (sub === 'lock') {
    if (rest.length === 0) {
      console.error('[furnace lock] requires a positional ETH amount, e.g. `furnace lock 0.05`');
      return 64;
    }
    const ethArg = String(rest[0]);
    if (ethArg.startsWith('--')) {
      console.error('[furnace lock] first positional must be the ETH amount, e.g. `furnace lock 0.05`');
      return 64;
    }
    const tail = rest.slice(1);
    if (tail.includes('--eth') || tail.includes('--claim') || tail.includes('--token')) {
      console.error('[furnace lock] do not pass --eth/--claim/--token; the positional ETH amount is used.');
      return 64;
    }
    return await runLock(['--eth', ethArg, ...tail]);
  }

  if (sub === 'status') {
    return await runStatus(rest);
  }

  console.error(`[furnace] unknown subcommand: ${sub}`);
  console.error(HELP);
  return 64;
}
