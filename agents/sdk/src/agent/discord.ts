import type { Address } from 'viem';
import { formatEther } from 'viem';

import type { AgentAction, AgentActionResult, AgentPlan } from './types.js';

const TIMEOUT_MS = 5_000;

type DiscordEmbed = {
  title?: string;
  description?: string;
  color?: number;
  fields?: Array<{ name: string; value: string; inline?: boolean }>;
  timestamp?: string;
  footer?: { text: string };
};

type DiscordPayload = {
  content?: string;
  embeds?: DiscordEmbed[];
};

function shortenAddress(addr: string): string {
  if (addr.length <= 12) return addr;
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function actionLabel(action: AgentAction): string {
  switch (action.kind) {
    case 'mineCore.takeover':
      return `Takeover (${formatEther(action.price)} ETH)`;
    case 'mineCore.takeoverFor':
      return `TakeoverFor ${shortenAddress(action.newKing)} (${formatEther(action.price)} ETH)`;
    case 'mineCore.takeoverWithToken':
      return `TakeoverWithToken ${shortenAddress(action.tokenIn)}`;
    case 'furnace.enterWithEth':
    case 'furnace.enterWithEthFor':
      return `Furnace enter (${formatEther(action.ethIn)} ETH)`;
    case 'royalties.claimShareholderEth':
      return `Collect royalties (${formatEther(action.claimable)} ETH)`;
    case 'mineCore.withdrawKingBalance':
      return `Withdraw king balance (${formatEther(action.amount)} ETH)`;
    case 'mineCore.withdrawRefundBalance':
      return `Withdraw refund (${formatEther(action.amount)} ETH)`;
    default:
      return action.kind;
  }
}

function isTakeoverAction(kind: string): boolean {
  return (
    kind === 'mineCore.takeover' ||
    kind === 'mineCore.takeoverFor' ||
    kind === 'mineCore.takeoverWithToken'
  );
}

const COLOR_GREEN = 0x2ecc71;
const COLOR_RED = 0xe74c3c;
const COLOR_BLUE = 0x3498db;
const COLOR_YELLOW = 0xf39c12;
const COLOR_GRAY = 0x95a5a6;

async function postWebhook(url: string, payload: DiscordPayload): Promise<void> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  (timer as any).unref?.();

  try {
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
  } catch {
    // Fire-and-forget; never let Discord failures affect the bot.
  } finally {
    clearTimeout(timer);
  }
}

export class DiscordNotifier {
  private readonly url: string;
  private readonly chain: string;

  constructor(params: { webhookUrl: string; chain: string }) {
    this.url = params.webhookUrl;
    this.chain = params.chain;
  }

  async notifyStarted(params: {
    agent: Address;
    user: Address;
    delegated: boolean;
    execute: boolean;
    chainId: number;
    enableTakeovers: boolean;
    maxTakeoverEth: bigint;
  }): Promise<void> {
    const fields: DiscordEmbed['fields'] = [
      { name: 'Chain', value: `${this.chain} (${params.chainId})`, inline: true },
      { name: 'Mode', value: params.execute ? 'LIVE' : 'DRY-RUN', inline: true },
      { name: 'Takeovers', value: params.enableTakeovers ? 'enabled' : 'disabled', inline: true },
      { name: 'Bot', value: `\`${shortenAddress(params.agent)}\``, inline: true },
    ];

    if (params.delegated) {
      fields.push({
        name: 'Playing for',
        value: `\`${shortenAddress(params.user)}\``,
        inline: true,
      });
    }

    if (params.enableTakeovers && params.maxTakeoverEth > 0n) {
      fields.push({
        name: 'Max takeover',
        value: `${formatEther(params.maxTakeoverEth)} ETH`,
        inline: true,
      });
    }

    await postWebhook(this.url, {
      embeds: [
        {
          title: 'Bot Started',
          color: COLOR_BLUE,
          fields,
          timestamp: new Date().toISOString(),
          footer: { text: 'ClaimRush Agent' },
        },
      ],
    });
  }

  async notifyActionResult(res: AgentActionResult): Promise<void> {
    const takeover = isTakeoverAction(res.action.kind);
    const label = actionLabel(res.action);

    if (res.simulated) {
      // Only notify simulated takeovers (skip routine dry-run noise).
      if (!takeover) return;

      await postWebhook(this.url, {
        embeds: [
          {
            title: 'Simulated Action',
            description: label,
            color: COLOR_GRAY,
            timestamp: new Date().toISOString(),
            footer: { text: 'ClaimRush Agent (dry-run)' },
          },
        ],
      });
      return;
    }

    if (res.error) {
      await postWebhook(this.url, {
        embeds: [
          {
            title: 'Action Failed',
            description: label,
            color: COLOR_RED,
            fields: [
              {
                name: 'Error',
                value: `\`\`\`${String(res.error).slice(0, 500)}\`\`\``,
              },
              ...(res.hash ? [{ name: 'Tx', value: `\`${res.hash}\``, inline: true }] : []),
            ],
            timestamp: new Date().toISOString(),
            footer: { text: 'ClaimRush Agent' },
          },
        ],
      });
      return;
    }

    // Successful execution -- always notify for takeovers, skip for routine actions.
    if (!takeover) return;

    const fields: DiscordEmbed['fields'] = [];
    if (res.hash) {
      fields.push({ name: 'Tx', value: `\`${res.hash}\``, inline: true });
    }
    if (res.receiptBlockNumber !== undefined) {
      fields.push({
        name: 'Block',
        value: res.receiptBlockNumber.toString(),
        inline: true,
      });
    }

    await postWebhook(this.url, {
      embeds: [
        {
          title: 'Takeover Executed',
          description: label,
          color: COLOR_GREEN,
          fields,
          timestamp: new Date().toISOString(),
          footer: { text: 'ClaimRush Agent' },
        },
      ],
    });
  }

  async notifyPlan(plan: AgentPlan): Promise<void> {
    if (!plan.actions.length) return;

    const hasTakeover = plan.actions.some((a) => isTakeoverAction(a.kind));
    if (!hasTakeover) return;

    const lines = plan.actions.slice(0, 10).map((a) => `- ${actionLabel(a)}`);
    if (plan.actions.length > 10) lines.push(`- ... +${plan.actions.length - 10} more`);

    await postWebhook(this.url, {
      embeds: [
        {
          title: 'Plan (tick)',
          description: lines.join('\n'),
          color: COLOR_YELLOW,
          fields: [{ name: 'Block', value: plan.blockNumber.toString(), inline: true }],
          timestamp: new Date().toISOString(),
          footer: { text: 'ClaimRush Agent' },
        },
      ],
    });
  }

  async notifyError(error: unknown): Promise<void> {
    const msg = error instanceof Error ? error.message : String(error);
    await postWebhook(this.url, {
      embeds: [
        {
          title: 'Bot Error',
          description: `\`\`\`${msg.slice(0, 1000)}\`\`\``,
          color: COLOR_RED,
          timestamp: new Date().toISOString(),
          footer: { text: 'ClaimRush Agent' },
        },
      ],
    });
  }

  async notifyStopped(): Promise<void> {
    await postWebhook(this.url, {
      embeds: [
        {
          title: 'Bot Stopped',
          color: COLOR_GRAY,
          timestamp: new Date().toISOString(),
          footer: { text: 'ClaimRush Agent' },
        },
      ],
    });
  }
}
