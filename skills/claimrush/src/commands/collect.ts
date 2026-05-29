import type { AgentAction } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { buildWriteContext, parseCommonFlags, submitActions } from '../util/executor.js';
import { parseBigIntStrict, parseEthStrict, jsonStringify } from '../safety/cral.js';

const HELP = `claimrush collect - Collect ETH royalties (royalties.claimShareholderEth | claimShareholderLock)

USAGE
  claimrush collect --mode eth   [--min-eth 0] [--execute]
  claimrush collect --mode lock  --duration-days 30 [--target-token-id 0|N] [--auto-max] [--slippage-bps 50] [--execute]

MODES
  --mode eth     Pull ETH royalties to caller (royalties.claimShareholderEth).
                 Set --min-eth to enforce a minimum collectible amount.

  --mode lock    Compound ETH royalties straight into a Furnace lock
                 (routes through ShareholderRoyalties.claimShareholderToFurnace).
                 Use --target-token-id to extend an existing lock or 0 for new.

COMMON
  --acting-for 0xUser    Delegated mode (claimAllHelper.claimShareholderForUser).
  --chain / --rpc-url / --execute / --i-understand / --pretty
`;

export async function runCollect(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }
  const common = parseCommonFlags(argv);

  const mode = f.get('mode') ?? 'eth';
  if (mode !== 'eth' && mode !== 'lock') {
    console.error(`[collect] --mode must be 'eth' or 'lock' (got ${mode})`);
    return 64;
  }

  const ctx = await buildWriteContext(common);

  // Read live collectible ETH up-front so the receipt always shows the user
  // exactly what is being collected (CRAL: re-quote at send).
  const royalties = (ctx.contracts as any).ShareholderRoyalties;
  if (!royalties) {
    console.error('[collect] ShareholderRoyalties not found in manifest for chain');
    return 70;
  }
  const subjectAddress = ctx.actingForUser ?? ctx.agent;
  const claimable = (await royalties.read.claimableEth([subjectAddress])) as bigint;

  if (mode === 'eth') {
    const minEthStr = f.get('min-eth');
    const minEth = minEthStr ? parseEthStrict(minEthStr, 'min-eth') : 0n;
    if (claimable < minEth) {
      console.log(
        jsonStringify(
          {
            ok: false,
            stage: 'pre-quote',
            reason: 'collectible below --min-eth',
            collectible: claimable.toString(),
            minEth: minEth.toString(),
            subject: subjectAddress,
          },
          ctx.pretty,
        ),
      );
      return 65;
    }
    let actions: AgentAction[];
    if (ctx.actingForUser) {
      actions = [
        {
          kind: 'claimAllHelper.claimShareholderForUser',
          user: ctx.actingForUser,
          claimable,
          mode: 0,
          targetTokenId: 0n,
          durationSeconds: 0n,
          createAutoMax: false,
          minVeOut: 0n,
        },
      ];
    } else {
      actions = [{ kind: 'royalties.claimShareholderEth', claimable }];
    }
    const submission = await submitActions(ctx, actions, {
      cralAction: 'collect',
      receiptName: 'collect',
      notes: { mode, collectible: claimable.toString() },
    });
    return submission.exitCode;
  }

  // mode === 'lock'
  const durationDays = f.get('duration-days') ? Number(f.get('duration-days')) : 30;
  const durationSeconds = BigInt(Math.floor(durationDays * 86_400));
  const targetTokenId = f.get('target-token-id')
    ? parseBigIntStrict(f.get('target-token-id') as string, 'target-token-id')
    : 0n;
  const createAutoMax = f.has('auto-max');
  const slippageBps = f.get('slippage-bps')
    ? parseBigIntStrict(f.get('slippage-bps') as string, 'slippage-bps')
    : 50n;

  let actions: AgentAction[];
  if (ctx.actingForUser) {
    actions = [
      {
        kind: 'claimAllHelper.claimShareholderForUser',
        user: ctx.actingForUser,
        claimable,
        mode: 1,
        targetTokenId,
        durationSeconds,
        createAutoMax,
        minVeOut: 0n,
      },
    ];
  } else {
    actions = [
      {
        kind: 'royalties.claimShareholderLock',
        targetTokenId,
        durationSeconds,
        createAutoMax,
        slippageBps,
      },
    ];
  }
  const submission = await submitActions(ctx, actions, {
    cralAction: 'collect',
    slippageBps,
    deadlineSeconds: 60n,
    receiptName: 'collect',
    notes: {
      mode,
      collectible: claimable.toString(),
      durationDays,
      targetTokenId: targetTokenId.toString(),
    },
  });
  return submission.exitCode;
}
