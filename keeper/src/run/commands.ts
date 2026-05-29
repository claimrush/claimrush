import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { FileLock } from '../shared/lock.js';
import type { ViemClients } from '../shared/clients.js';
import type { CliOptions } from './cli.js';

import { runPokeOnce } from '../tasks/poke.js';
import { runHarvestStaking } from '../tasks/harvest_staking.js';
import { runSweepMarket } from '../tasks/sweep_market.js';
import { runSweepListings } from '../tasks/sweep_listings.js';
import { runExpireOffers } from '../tasks/expire_offers.js';
import { runCompoundShareholders } from '../tasks/compound_shareholders.js';
import { runCompoundLp } from '../tasks/compound_lp.js';
import { runCheckpointBeforeExpiry } from '../tasks/checkpoint_before_expiry.js';
import { runAutomaxBonusOnce } from '../tasks/automax_bonus.js';
import { runDaemon } from './daemon.js';
import { usage } from './cli.js';

type CommandContext = {
  cli: CliOptions;
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: (msg: string) => void;
  lock: FileLock;
};

export async function dispatchKeeperCommand(ctx: CommandContext): Promise<void> {
  const { cli, config, manifest, clients, log, lock } = ctx;

  if (cli.command === 'poke') {
    await runPokeOnce({ config, manifest, clients, log });
    return;
  }
  if (cli.command === 'harvest-staking') {
    await runHarvestStaking({ config, manifest, clients, log });
    return;
  }
  if (cli.command === 'sweep-market') {
    await runSweepMarket({ config, manifest, clients, log });
    return;
  }
  if (cli.command === 'sweep-listings') {
    await runSweepListings({ config, manifest, clients, log });
    return;
  }
  if (cli.command === 'expire-offers') {
    await runExpireOffers({ config, manifest, clients, log });
    return;
  }
  if (cli.command === 'compound-shareholders') {
    await runCompoundShareholders({ config, manifest, clients, morningCache: null, log });
    return;
  }
  if (cli.command === 'compound-lp') {
    await runCompoundLp({ config, manifest, clients, morningCache: null, log });
    return;
  }
  if (cli.command === 'checkpoint-before-expiry') {
    await runCheckpointBeforeExpiry({ config, manifest, clients, log });
    return;
  }
  if (cli.command === 'automax-bonus') {
    await runAutomaxBonusOnce({ config, manifest, clients, morningCache: null, log });
    return;
  }
  if (cli.command === 'daemon') {
    await runDaemon({ cli, config, manifest, clients, log, lock });
    return;
  }

  usage();
}
