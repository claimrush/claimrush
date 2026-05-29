import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';

import { runPokeOnce } from '../tasks/poke.js';
import { runHarvestStaking } from '../tasks/harvest_staking.js';
import { runSweepMarket } from '../tasks/sweep_market.js';
import { runSweepListings } from '../tasks/sweep_listings.js';
import { runExpireOffers } from '../tasks/expire_offers.js';
import { runCompoundShareholders } from '../tasks/compound_shareholders.js';
import { runCompoundLp } from '../tasks/compound_lp.js';
import { runCheckpointBeforeExpiry } from '../tasks/checkpoint_before_expiry.js';
import { runAutomaxBonusOnce } from '../tasks/automax_bonus.js';
import type { LogFn, TaskDef } from './types.js';
import type { MorningCache } from '../shared/user_morning.js';
import { loadMorningCache, refreshMorningCache } from '../shared/user_morning.js';

let _morningCache: MorningCache | null = null;
let _morningCacheLoaded = false;

async function getMorningCache(config: KeeperConfig, _log: LogFn): Promise<MorningCache | null> {
  if (!config.subgraphUrl) return null;

  if (!_morningCacheLoaded) {
    _morningCache = loadMorningCache(config.morningCachePath);
    _morningCacheLoaded = true;
  }
  return _morningCache;
}

export async function refreshMorningCacheForRewardTasks(
  config: KeeperConfig,
  users: string[],
  log: LogFn,
): Promise<void> {
  if (!config.subgraphUrl) return;
  _morningCache = await refreshMorningCache({
    cachePath: config.morningCachePath,
    subgraphUrl: config.subgraphUrl,
    users,
    log,
  });
  _morningCacheLoaded = true;
}

export function buildDaemonTaskDefs(args: {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: LogFn;
}): Record<string, TaskDef> {
  const { config, manifest, clients, log } = args;
  return {
    poke: {
      name: 'poke',
      statusKey: 'poke',
      intervalSecs: config.pokeIntervalSecs,
      run: async () => runPokeOnce({ config, manifest, clients, log }),
    },
    'harvest-staking': {
      name: 'harvest-staking',
      statusKey: 'harvestStaking',
      intervalSecs: config.harvestStakingIntervalSecs,
      run: async () => runHarvestStaking({ config, manifest, clients, log }),
    },
    'sweep-market': {
      name: 'sweep-market',
      statusKey: 'autoFurnace',
      intervalSecs: config.sweepMarketIntervalSecs,
      run: async () => runSweepMarket({ config, manifest, clients, log }),
    },
    'sweep-listings': {
      name: 'sweep-listings',
      statusKey: 'sweepListings',
      intervalSecs: config.sweepListingsIntervalSecs,
      run: async () => runSweepListings({ config, manifest, clients, log }),
    },
    'expire-offers': {
      name: 'expire-offers',
      statusKey: 'expireOffers',
      intervalSecs: config.expireOffersIntervalSecs,
      run: async () => runExpireOffers({ config, manifest, clients, log }),
    },
    'compound-shareholders': {
      name: 'compound-shareholders',
      statusKey: 'compoundShareholders',
      intervalSecs: config.compoundShareholdersIntervalSecs,
      run: async () => {
        const mc = await getMorningCache(config, log);
        return runCompoundShareholders({ config, manifest, clients, morningCache: mc, log });
      },
    },
    'compound-lp': {
      name: 'compound-lp',
      statusKey: 'compoundLp',
      intervalSecs: config.compoundLpIntervalSecs,
      run: async () => {
        const mc = await getMorningCache(config, log);
        return runCompoundLp({ config, manifest, clients, morningCache: mc, log });
      },
    },
    'checkpoint-before-expiry': {
      name: 'checkpoint-before-expiry',
      statusKey: 'checkpointBeforeExpiry',
      intervalSecs: config.checkpointBeforeExpiryIntervalSecs,
      run: async () => runCheckpointBeforeExpiry({ config, manifest, clients, log }),
    },
    'automax-bonus': {
      name: 'automax-bonus',
      statusKey: 'automaxBonus',
      intervalSecs: config.automaxBonusIntervalSecs,
      run: async () => {
        const mc = await getMorningCache(config, log);
        return runAutomaxBonusOnce({ config, manifest, clients, morningCache: mc, log });
      },
    },
  };
}
