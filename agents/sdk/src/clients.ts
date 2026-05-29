import { parseAndValidateOutboundUrl, parseAndValidateOutboundUrlWithDns } from './security/url.js';

import {
  createPublicClient,
  createWalletClient,
  http,
  type Account,
  type Chain,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem';

export type CreateClaimRushClientsParams = {
  rpcUrl: string;
  chain?: Chain;
  /** Optional viem Account for wallet client. If omitted, only a PublicClient is created. */
  account?: Account;
};

export type ClaimRushClients = {
  publicClient: PublicClient<Transport, Chain | undefined>;
  walletClient?: WalletClient<Transport, Chain | undefined, Account>;
};

/**
 * Convenience builder for viem clients.
 *
 * Notes
 * - If you pass an `account`, you get a `walletClient` suitable for `writeContract`.
 * - If you omit an `account`, you only get a `publicClient`.
 *
 * SECURITY: This function validates the RPC URL syntactically and rejects
 * IP LITERAL hosts that fall in denied ranges (loopback, private, link-local,
 * etc.) based on the literal host in the URL. It does NOT resolve hostnames
 * to IPs synchronously, because the builder is sync. A misconfigured
 * hostname that resolves to a private IP (classic DNS-SSRF) would still be
 * accepted by this sync builder. For that class of threat, call
 * {@link createClaimRushClientsAsync}, which runs the resolved-IP policy
 * BEFORE building the transport and rejects the URL if any resolved address
 * is in a denied range. This sync entry additionally fires a best-effort
 * background DNS check and prints a loud stderr warning if it finds a
 * resolved-IP violation, so a misconfiguration is still visible in logs.
 */
export function createClaimRushClients(params: CreateClaimRushClientsParams): ClaimRushClients {
  const parsed = parseAndValidateOutboundUrl(params.rpcUrl, 'createClaimRushClients.rpcUrl', {
    allowCredentials: true,
  });
  const rpcUrl = parsed.toString();

  // Cleartext HTTP to a non-loopback RPC endpoint is almost always a
  // misconfiguration: transaction payloads (including signed raw txs) and any
  // auth token embedded in the URL would traverse the network in plaintext.
  // We warn loudly on the first client build and let integrators opt out
  // with CLAIMRUSH_ALLOW_PLAINTEXT_RPC=1 when they are knowingly using a
  // trusted private link (e.g. Cloudflare-tunnelled proxy).
  try {
    const isHttp = parsed.protocol.toLowerCase() === 'http:';
    const host = parsed.hostname.toLowerCase();
    const isLoopback =
      host === 'localhost' ||
      host === '127.0.0.1' ||
      host === '::1' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local');
    const allow = (process.env.CLAIMRUSH_ALLOW_PLAINTEXT_RPC ?? '').trim().toLowerCase();
    const bypass = allow === '1' || allow === 'true' || allow === 'yes';
    if (isHttp && !isLoopback && !bypass) {
      console.warn(
        `[ClaimRush SDK] WARNING: RPC URL is cleartext HTTP to a non-loopback host (${host}). ` +
          `Signed transactions and any auth token in the URL will traverse the network unencrypted. ` +
          `Use https:// for remote endpoints, or set CLAIMRUSH_ALLOW_PLAINTEXT_RPC=1 to silence this warning ` +
          `if you are knowingly connecting over a trusted private link.`,
      );
    }
  } catch {
    /* URL parsing is already validated above; swallow any unexpected access errors. */
  }

  // Disallow HTTP redirects for RPC calls to reduce SSRF pivot risk.
  const transport = http(rpcUrl, {
    fetchOptions: {
      redirect: 'error',
    },
  });

  const publicClient = createPublicClient({
    chain: params.chain,
    transport,
  });

  const walletClient = params.account
    ? createWalletClient({
        chain: params.chain,
        transport,
        account: params.account,
      })
    : undefined;

  // Best-effort background DNS validation. We don't await: making this sync
  // function block on DNS would break the public API contract, and raising
  // a promise rejection upward here would require callers to add `.catch`.
  // Instead we resolve the URL's host in the background; if the resolved
  // IPs violate the outbound policy we print a loud stderr warning so
  // operators can catch misconfigurations (e.g. a hostname that resolves
  // to 169.254.169.254 or 10.0.0.x). Integrators who need hard enforcement
  // should use createClaimRushClientsAsync instead.
  void parseAndValidateOutboundUrlWithDns(rpcUrl, 'createClaimRushClients.rpcUrl', {
    allowCredentials: true,
  }).catch((err) => {
    try {
      console.warn(
        `[ClaimRush SDK] WARNING: RPC URL '${parsed.hostname}' failed background DNS/IP policy check: ` +
          `${String((err as Error)?.message ?? err)}. ` +
          `Use createClaimRushClientsAsync() to enforce this synchronously.`,
      );
    } catch {
      /* best-effort */
    }
  });

  return { publicClient, walletClient };
}

/**
 * Async variant of {@link createClaimRushClients} that performs DNS-resolved
 * IP policy validation BEFORE building the transport. Use this when the RPC
 * URL may be operator-controlled (env var, config file) and you need to
 * block hostnames that resolve to loopback / link-local / private /
 * metadata addresses (classic DNS-SSRF / misconfiguration defense).
 */
export async function createClaimRushClientsAsync(
  params: CreateClaimRushClientsParams,
): Promise<ClaimRushClients> {
  // Resolve and validate BEFORE building the transport. Throws on any
  // denied-IP resolution (loopback/private/link-local/metadata/denylisted).
  await parseAndValidateOutboundUrlWithDns(params.rpcUrl, 'createClaimRushClientsAsync.rpcUrl', {
    allowCredentials: true,
  });
  return createClaimRushClients(params);
}
