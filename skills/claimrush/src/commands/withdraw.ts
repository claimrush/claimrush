import { getAddress, isAddress, type Address } from 'viem';

import type { AgentAction } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { buildWriteContext, parseCommonFlags, submitActions } from '../util/executor.js';
import { parseEthStrict, jsonStringify } from '../safety/cral.js';

const HELP = `claimrush withdraw - drain MineCore king/refund balances to your wallet

USAGE
  claimrush withdraw --king [--min-eth 0] [--execute]
  claimrush withdraw --refund [--to 0xRecipient] [--min-eth 0] [--execute]

OPTIONS
  --king                       Withdraw from the king bucket.
  --refund                     Withdraw from the refund bucket.
  --to 0xRecipient             (refund only) recipient; defaults to the agent address.
  --min-eth <E>                Skip if available balance below this threshold.
  --acting-for 0xUser          Delegated mode (claimAllHelper.withdrawKingBalanceForUser).
  --chain / --rpc-url / --execute / --i-understand / --pretty

NOTES
  - Reads the live MineCore.kingBalance / MineCore.refundBalance so the receipt
    always shows the exact amount being withdrawn.
`;

export async function runWithdraw(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }
  const common = parseCommonFlags(argv);

  const isKing = f.has('king');
  const isRefund = f.has('refund');
  if (isKing === isRefund) {
    console.error('[withdraw] choose exactly one of --king or --refund');
    return 64;
  }

  const ctx = await buildWriteContext(common);
  const mineCore = (ctx.contracts as any).MineCore;
  if (!mineCore) {
    console.error('[withdraw] MineCore not found in manifest for chain');
    return 70;
  }

  const subject = ctx.actingForUser ?? ctx.agent;
  const minEthStr = f.get('min-eth');
  const minEth = minEthStr ? parseEthStrict(minEthStr, 'min-eth') : 0n;

  if (isKing) {
    const balance = (await mineCore.read.kingBalance([subject])) as bigint;
    if (balance < minEth) {
      console.log(
        jsonStringify(
          {
            ok: false,
            stage: 'pre-quote',
            reason: 'kingBalance below --min-eth',
            balance: balance.toString(),
            minEth: minEth.toString(),
            subject,
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
          kind: 'claimAllHelper.withdrawKingBalanceForUser',
          user: ctx.actingForUser,
          amount: balance,
        },
      ];
    } else {
      actions = [{ kind: 'mineCore.withdrawKingBalance', amount: balance }];
    }
    const submission = await submitActions(ctx, actions, {
      cralAction: 'withdraw',
      receiptName: 'withdraw',
      notes: { kind: 'king', subject, balance: balance.toString() },
    });
    return submission.exitCode;
  }

  // refund
  if (ctx.actingForUser) {
    console.error('[withdraw] --refund has no delegated variant; refund is always claimable by the recipient address.');
    return 64;
  }
  const toRaw = f.get('to');
  let toAddr: Address = ctx.agent;
  if (toRaw) {
    if (!isAddress(toRaw)) {
      console.error(`[withdraw] --to is not a valid address: ${toRaw}`);
      return 64;
    }
    toAddr = getAddress(toRaw) as Address;
  }
  const balance = (await mineCore.read.refundBalance([ctx.agent])) as bigint;
  if (balance < minEth) {
    console.log(
      jsonStringify(
        {
          ok: false,
          stage: 'pre-quote',
          reason: 'refundBalance below --min-eth',
          balance: balance.toString(),
          minEth: minEth.toString(),
          subject: ctx.agent,
        },
        ctx.pretty,
      ),
    );
    return 65;
  }
  const actions: AgentAction[] = [
    { kind: 'mineCore.withdrawRefundBalance', amount: balance, to: toAddr },
  ];
  const submission = await submitActions(ctx, actions, {
    cralAction: 'withdraw',
    receiptName: 'withdraw',
    notes: { kind: 'refund', to: toAddr, balance: balance.toString() },
  });
  return submission.exitCode;
}
