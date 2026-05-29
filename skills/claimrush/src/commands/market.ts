import type { AgentAction } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { buildWriteContext, parseCommonFlags, submitActions } from '../util/executor.js';
import { parseBigIntStrict } from '../safety/cral.js';

const HELP = `claimrush market - veNFT marketplace actions (MarketRouter)

USAGE
  claimrush market list --token-id <N> --min-claim-out <N> --ttl-seconds <N>
  claimrush market delist --token-id <N>
  claimrush market sell-to-furnace --token-id <N> [--slippage-bps 50] [--deadline-seconds 60]
  claimrush market sell-listed --token-id <N> [--deadline-seconds 60]
  claimrush market cancel-expired --token-id <N>

  claimrush market offer-create --target-bps <N> --budget-claim <wei>
                                 [--duration-seconds <N>] [--auto-max] [--ttl-seconds <N>]
                                 [--destination-lock-id <N>] [--slippage-bps 50]
  claimrush market offer-cancel --offer-id <N>
  claimrush market offer-extend --offer-id <N> --ttl-seconds-from-now <N>
  claimrush market offer-cancel-expired --offer-id <N>
  claimrush market offer-execute-auto-furnace --offer-id <N>

OPTIONS
  --execute / --i-understand / --pretty / --chain / --rpc-url / --acting-for
  (delegated mode: market actions are NOT delegated; --acting-for is rejected.)
`;

const SUBCOMMANDS = [
  'list',
  'delist',
  'sell-to-furnace',
  'sell-listed',
  'cancel-expired',
  'offer-create',
  'offer-cancel',
  'offer-extend',
  'offer-cancel-expired',
  'offer-execute-auto-furnace',
] as const;
type Sub = (typeof SUBCOMMANDS)[number];

export async function runMarket(argv: string[]): Promise<number> {
  if (helpRequested(argv) || argv.length === 0) {
    console.log(HELP);
    return 0;
  }
  const sub = String(argv[0]) as Sub;
  if (!SUBCOMMANDS.includes(sub)) {
    console.error(`[market] unknown subcommand: ${sub}`);
    console.error(HELP);
    return 64;
  }

  const rest = argv.slice(1);
  const f = makeFlagBag(rest);
  const common = parseCommonFlags(rest);
  if (common.actingFor) {
    console.error('[market] market actions are not delegated; --acting-for is rejected.');
    return 64;
  }

  const ctx = await buildWriteContext(common);

  const tokenId = f.get('token-id') ? parseBigIntStrict(f.get('token-id') as string, 'token-id') : 0n;
  const offerId = f.get('offer-id') ? parseBigIntStrict(f.get('offer-id') as string, 'offer-id') : 0n;
  const slippageBps = f.get('slippage-bps')
    ? parseBigIntStrict(f.get('slippage-bps') as string, 'slippage-bps')
    : 50n;
  const deadlineSeconds = f.get('deadline-seconds')
    ? parseBigIntStrict(f.get('deadline-seconds') as string, 'deadline-seconds')
    : 60n;
  const ttlSeconds = f.get('ttl-seconds')
    ? parseBigIntStrict(f.get('ttl-seconds') as string, 'ttl-seconds')
    : 0n;

  let actions: AgentAction[];
  let receiptName = `market-${sub}`;

  switch (sub) {
    case 'list': {
      const minClaimOut = f.get('min-claim-out')
        ? parseBigIntStrict(f.get('min-claim-out') as string, 'min-claim-out')
        : 0n;
      actions = [{ kind: 'marketRouter.listLock', tokenId, minClaimOut, ttlSeconds }];
      break;
    }
    case 'delist':
      actions = [{ kind: 'marketRouter.delistLock', tokenId }];
      break;
    case 'sell-to-furnace':
      actions = [
        { kind: 'marketRouter.sellLockToFurnace', tokenId, slippageBps, deadlineSeconds },
      ];
      break;
    case 'sell-listed':
      actions = [{ kind: 'marketRouter.sellListedLockToFurnace', tokenId, deadlineSeconds }];
      break;
    case 'cancel-expired':
      actions = [{ kind: 'marketRouter.cancelExpiredListing', tokenId }];
      break;
    case 'offer-create': {
      const targetBonusBps = parseBigIntStrict(f.get('target-bps') ?? '', 'target-bps');
      const budgetClaim = parseBigIntStrict(f.get('budget-claim') ?? '', 'budget-claim');
      const durationSeconds = f.get('duration-seconds')
        ? parseBigIntStrict(f.get('duration-seconds') as string, 'duration-seconds')
        : 0n;
      const escrowTtlSeconds = ttlSeconds;
      const destinationLockId = f.get('destination-lock-id')
        ? parseBigIntStrict(f.get('destination-lock-id') as string, 'destination-lock-id')
        : 0n;
      const createAutoMax = f.has('auto-max');
      actions = [
        {
          kind: 'marketRouter.createBonusTargetEscrowWithTarget',
          targetBonusBps,
          budgetClaim,
          durationSeconds,
          createAutoMax,
          escrowTtlSeconds,
          destinationLockId,
          slippageBps,
        },
      ];
      break;
    }
    case 'offer-cancel':
      actions = [{ kind: 'marketRouter.cancelBonusTargetEscrow', offerId }];
      break;
    case 'offer-extend': {
      const ttlSecondsFromNow = parseBigIntStrict(
        f.get('ttl-seconds-from-now') ?? '',
        'ttl-seconds-from-now',
      );
      actions = [
        { kind: 'marketRouter.extendBonusTargetEscrowExpiry', offerId, ttlSecondsFromNow },
      ];
      break;
    }
    case 'offer-cancel-expired':
      actions = [{ kind: 'marketRouter.cancelExpiredBonusTargetEscrow', offerId }];
      break;
    case 'offer-execute-auto-furnace':
      actions = [{ kind: 'marketRouter.executeAutoFurnace', offerId }];
      break;
  }

  const slippageRelevant: Sub[] = ['sell-to-furnace', 'offer-create'];
  const submission = await submitActions(ctx, actions, {
    cralAction: 'market',
    slippageBps: slippageRelevant.includes(sub) ? slippageBps : undefined,
    deadlineSeconds:
      sub === 'sell-to-furnace' || sub === 'sell-listed' ? deadlineSeconds : undefined,
    receiptName,
    notes: { sub, tokenId: tokenId.toString(), offerId: offerId.toString() },
  });
  return submission.exitCode;
}
