import { getAddress, isAddress, type Address } from 'viem';

import type { AgentAction } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { buildWriteContext, parseCommonFlags, submitActions } from '../util/executor.js';
import { parseBigIntStrict, parseEthStrict } from '../safety/cral.js';

const HELP = `claimrush lock - lock value into the Furnace (furnace.enterWith*)

USAGE
  claimrush lock --eth 0.01           [--duration-days 30] [--target-token-id 0|N]
                                       [--auto-max] [--slippage-bps 50] [--execute]
  claimrush lock --claim 1000         [--duration-days 30] [--auto-max] [--slippage-bps 50] [--execute]
  claimrush lock --token 0xToken --amount-in <wei>
                                       [--duration-days 30] [--auto-max] [--slippage-bps 50] [--execute]

REQUIRED (one of)
  --eth <E>                Furnace.enterWithEth (or enterWithEthFor when --acting-for is set).
  --claim <N>              Furnace.enterWithClaim using N CLAIM (decimals = 18).
  --token 0xToken --amount-in <wei>
                           Furnace.enterWithToken (raw base units).

COMMON
  --target-token-id N      Existing veNFT id to extend, or 0 to mint a new lock.
  --duration-days N        Lock duration in days (default 30).
  --auto-max               Use AutoMax (locks at MAX duration). Overrides --duration-days.
  --slippage-bps N         Slippage tolerance (default: 50; capped by CR_SKILL_MAX_SLIPPAGE_BPS).
  --acting-for 0xUser      Delegated entry (uses *For variant).
  --chain / --rpc-url / --execute / --i-understand / --pretty
`;

export async function runLock(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }
  const common = parseCommonFlags(argv);

  const ethStr = f.get('eth');
  const claimStr = f.get('claim');
  const tokenStr = f.get('token');
  const amountInStr = f.get('amount-in');

  const modes = [ethStr, claimStr, tokenStr].filter(Boolean).length;
  if (modes !== 1) {
    console.error('[lock] choose exactly one of --eth | --claim | --token');
    return 64;
  }

  const targetTokenId = f.get('target-token-id')
    ? parseBigIntStrict(f.get('target-token-id') as string, 'target-token-id')
    : 0n;
  const durationDays = f.get('duration-days') ? Number(f.get('duration-days')) : 30;
  const createAutoMax = f.has('auto-max');
  const slippageBps = f.get('slippage-bps')
    ? parseBigIntStrict(f.get('slippage-bps') as string, 'slippage-bps')
    : 50n;
  const durationSeconds = BigInt(Math.floor(durationDays * 86_400));

  const ctx = await buildWriteContext(common);

  let actions: AgentAction[];
  let spendCapWei: bigint | undefined;
  let spendCapKind: 'furnace' | 'other' = 'other';

  if (ethStr) {
    const ethIn = parseEthStrict(ethStr, 'eth');
    spendCapWei = ethIn;
    spendCapKind = 'furnace';
    if (ctx.actingForUser) {
      actions = [
        {
          kind: 'furnace.enterWithEthFor',
          user: ctx.actingForUser,
          ethIn,
          targetTokenId,
          durationSeconds,
          createAutoMax,
          slippageBps,
        },
      ];
    } else {
      actions = [
        {
          kind: 'furnace.enterWithEth',
          ethIn,
          targetTokenId,
          durationSeconds,
          createAutoMax,
          slippageBps,
        },
      ];
    }
  } else if (claimStr) {
    const claimIn = parseEthStrict(claimStr, 'claim'); // CLAIM has 18 decimals
    if (ctx.actingForUser) {
      actions = [
        {
          kind: 'furnace.enterWithClaimFromCallerFor',
          user: ctx.actingForUser,
          claimIn,
          targetTokenId,
          durationSeconds,
          createAutoMax,
          slippageBps,
        },
      ];
    } else {
      actions = [
        {
          kind: 'furnace.enterWithClaim',
          claimIn,
          targetTokenId,
          durationSeconds,
          createAutoMax,
          slippageBps,
        },
      ];
    }
  } else {
    if (!tokenStr || !amountInStr) {
      console.error('[lock] --token requires --amount-in <wei>');
      return 64;
    }
    if (!isAddress(tokenStr)) {
      console.error(`[lock] --token is not a valid address: ${tokenStr}`);
      return 64;
    }
    const tokenIn = getAddress(tokenStr) as Address;
    const amountIn = parseBigIntStrict(amountInStr, 'amount-in');
    if (ctx.actingForUser) {
      actions = [
        {
          kind: 'furnace.enterWithTokenFromCallerFor',
          user: ctx.actingForUser,
          tokenIn,
          amountIn,
          targetTokenId,
          durationSeconds,
          createAutoMax,
          slippageBps,
        },
      ];
    } else {
      actions = [
        {
          kind: 'furnace.enterWithToken',
          tokenIn,
          amountIn,
          targetTokenId,
          durationSeconds,
          createAutoMax,
          slippageBps,
        },
      ];
    }
  }

  const submission = await submitActions(ctx, actions, {
    cralAction: 'lock',
    spendCapKind,
    spendCapWei,
    slippageBps,
    deadlineSeconds: 60n,
    receiptName: 'lock',
    notes: { durationDays, durationSeconds: durationSeconds.toString() },
  });
  return submission.exitCode;
}
