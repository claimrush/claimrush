/**
 * Example “opportunistic takeover” strategy.
 *
 * If the current takeover price is <= MAX_TAKEOVER_ETH and the agent has enough ETH,
 * propose a single `mineCore.takeover` action.
 *
 * Enable by setting:
 * - MAX_TAKEOVER_ETH (e.g. "0.02")
 */

import { parseEther } from 'viem';

function parseMaxEth(v) {
  const s = String(v ?? '').trim();
  if (!s) return 0n;
  if (Number(s) === 0) return 0n;
  try {
    return parseEther(s);
  } catch {
    return 0n;
  }
}

const MAX_TAKEOVER_ETH = parseMaxEth(process.env.MAX_TAKEOVER_ETH);

export const strategies = [
  {
    id: 'takeover.underMaxEth',
    priority: 100,
    stopOnActions: true,

    propose: (ctx) => {
      if (MAX_TAKEOVER_ETH <= 0n) return;

      const s = ctx.snapshot;
      const user = s.user;
      if (!user) return;

      if (s.mineCore.takeoversPaused) {
        return { actions: [], notes: ['takeoversPaused'] };
      }

      // Already king, no reason to takeover.
      if (String(s.mineCore.currentKing).toLowerCase() === String(ctx.user).toLowerCase()) {
        return { actions: [], notes: ['alreadyKing'] };
      }

      const price = s.mineCore.currentTakeoverPrice;
      if (price === 0n) return;

      if (price > MAX_TAKEOVER_ETH) {
        return { actions: [], notes: [`priceTooHigh:${price.toString()}`] };
      }

      if (user.ethBalance < price) {
        return { actions: [], notes: [`insufficientEth:${user.ethBalance.toString()}`] };
      }

      return {
        actions: [{ kind: 'mineCore.takeover', price }],
        notes: [`takeover<=${MAX_TAKEOVER_ETH.toString()}`],
      };
    },
  },
];
