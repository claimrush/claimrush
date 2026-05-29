import { formatEther, getAddress, isAddress, type Address } from 'viem';

import {
  quoteCurrentTakeoverPrice,
  quoteTakeoverWithTokenMinOut,
} from '@claimrush/agent-sdk';
import type { AgentAction } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { buildWriteContext, parseCommonFlags, submitActions } from '../util/executor.js';
import { jsonStringify, parseEthStrict, parseBigIntStrict } from '../safety/cral.js';

const HELP = `claimrush takeover - take over the Mine (mineCore.takeover / takeoverWithToken)

USAGE
  # ETH path:
  claimrush takeover --eth --max-eth 0.001 [--deadline-seconds 60] [--execute]

  # ERC20 path (token swapped to ETH inside MineCore):
  claimrush takeover --token 0xToken --amount-in <wei> --slippage-bps 50 \\
                      --max-eth 0.001 [--execute]

REQUIRED
  --max-eth <E>            Hard upper bound on ETH paid for this takeover (CRAL cap).

ETH path
  --eth                    Use mineCore.takeover (price comes from quoteCurrentTakeoverPrice).

Token path
  --token 0xToken          ERC20 entry token to swap.
  --amount-in <wei>        Token amount in raw base units.
  --slippage-bps <bps>     Slippage tolerance for swap (default: 100; max via env).

COMMON
  --chain <name>           local | base_sepolia | base
  --rpc-url <url>
  --acting-for 0xUser      Delegated mode (uses mineCore.takeoverFor + DelegationHub).
  --deadline-seconds N     Tx deadline (5..3600, default 60).
  --execute                Send tx (default: dry-run).
  --i-understand           Required with --execute on --chain base.
  --pretty                 Pretty-print JSON.

NOTES
  - In --eth dry-run mode, prints quoteCurrentTakeoverPrice and the simulated
    plan. Confirm the price is below --max-eth before re-running with --execute.
  - In --token path, prints the MineCoreQuoter result (expectedEthOut +
    minEthOut) so you can verify slippage before --execute.
`;

export async function runTakeover(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }
  const common = parseCommonFlags(argv);

  const useEth = f.has('eth');
  const tokenStr = f.get('token');
  const useToken = !!tokenStr;
  if (useEth === useToken) {
    console.error('[takeover] choose exactly one of --eth or --token 0xToken');
    return 64;
  }

  const maxEthStr = f.get('max-eth');
  if (!maxEthStr) {
    console.error('[takeover] --max-eth <E> is required (hard CRAL cap)');
    return 64;
  }
  const maxEthWei = parseEthStrict(maxEthStr, 'max-eth');

  const deadlineSeconds = f.get('deadline-seconds')
    ? parseBigIntStrict(f.get('deadline-seconds') as string, 'deadline-seconds')
    : 60n;

  const ctx = await buildWriteContext(common);

  let actions: AgentAction[];
  let extra: Record<string, unknown> = {};
  let slippageBps: bigint | undefined;

  if (useEth) {
    const livePrice = await quoteCurrentTakeoverPrice({ contracts: ctx.contracts });
    extra = {
      mode: 'eth',
      currentTakeoverPrice: livePrice.toString(),
      currentTakeoverPriceEth: formatEther(livePrice),
      maxEthWei: maxEthWei.toString(),
    };
    if (livePrice > maxEthWei) {
      const receipt = {
        ok: false,
        stage: 'pre-quote',
        reason: `currentTakeoverPrice=${livePrice} exceeds --max-eth=${maxEthWei}`,
        ...extra,
      };
      console.log(jsonStringify(receipt, ctx.pretty));
      return 65;
    }
    if (ctx.actingForUser) {
      actions = [{ kind: 'mineCore.takeoverFor', newKing: ctx.actingForUser, price: livePrice }];
    } else {
      actions = [{ kind: 'mineCore.takeover', price: livePrice }];
    }
  } else {
    if (!isAddress(tokenStr!)) {
      console.error(`[takeover] --token is not a valid address: ${tokenStr}`);
      return 64;
    }
    const tokenIn = getAddress(tokenStr!) as Address;
    const amountInStr = f.get('amount-in');
    if (!amountInStr) {
      console.error('[takeover] --amount-in <wei> required for --token path');
      return 64;
    }
    const amountIn = parseBigIntStrict(amountInStr, 'amount-in');

    slippageBps = f.get('slippage-bps')
      ? parseBigIntStrict(f.get('slippage-bps') as string, 'slippage-bps')
      : 100n;

    const q = await quoteTakeoverWithTokenMinOut({
      contracts: ctx.contracts,
      tokenIn,
      amountIn,
      slippageBps,
    });
    if (q.minEthOut < q.takeoverPrice) {
      const receipt = {
        ok: false,
        stage: 'pre-quote',
        reason: 'quoted minEthOut below takeoverPrice; widen amountIn or accept higher slippage',
        quote: {
          takeoverPrice: q.takeoverPrice.toString(),
          ethOut: q.ethOut.toString(),
          minEthOut: q.minEthOut.toString(),
          slippageBps: slippageBps.toString(),
        },
      };
      console.log(jsonStringify(receipt, ctx.pretty));
      return 65;
    }
    if (q.minEthOut > maxEthWei) {
      const receipt = {
        ok: false,
        stage: 'pre-quote',
        reason: 'quoted minEthOut exceeds --max-eth cap',
        maxEthWei: maxEthWei.toString(),
        quote: {
          takeoverPrice: q.takeoverPrice.toString(),
          ethOut: q.ethOut.toString(),
          minEthOut: q.minEthOut.toString(),
          slippageBps: slippageBps.toString(),
        },
      };
      console.log(jsonStringify(receipt, ctx.pretty));
      return 65;
    }
    extra = {
      mode: 'token',
      tokenIn,
      amountIn: amountIn.toString(),
      slippageBps: slippageBps.toString(),
      quote: {
        takeoverPrice: q.takeoverPrice.toString(),
        takeoverPriceEth: formatEther(q.takeoverPrice),
        ethOut: q.ethOut.toString(),
        minEthOut: q.minEthOut.toString(),
        minEthOutEth: formatEther(q.minEthOut),
      },
    };
    actions = [
      {
        kind: 'mineCore.takeoverWithToken',
        tokenIn,
        amountIn,
        slippageBps,
      },
    ];
  }

  const submission = await submitActions(ctx, actions, {
    cralAction: 'takeover',
    spendCapWei: maxEthWei,
    spendCapKind: 'takeover',
    slippageBps,
    deadlineSeconds,
    receiptName: 'takeover',
    notes: extra,
  });
  return submission.exitCode;
}
