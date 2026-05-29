import type { Abi, Account, Address, PublicClient, WalletClient } from 'viem';
import { erc20Abi } from 'viem';

import { loadAbi } from '../abis.js';
import type { AbiNetwork } from '../abis.js';
import type { ClaimRushContracts } from '../contracts.js';
import type { DeploymentManifest } from '../manifest.js';
import {
  minOutFromBps,
  quoteEnterWithClaim,
  quoteEnterWithEth,
  quoteEnterWithToken,
  quoteSellLockToFurnace,
  quoteTakeoverWithTokenMinOut,
} from '../quotes.js';
import { classifyViemError } from '../errors.js';
import { simulateAndWrite, TxRevertedError } from '../harness/tx.js';
import { safeErrorString } from '../security/redact.js';
import type { TxManager } from '../tx/txManager.js';
import { TxTimeoutError } from '../tx/txManager.js';
import {
  describePerms,
  P_CLAIM_ALL_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_FURNACE_ENTER_CLAIM_FOR,
  P_FURNACE_ENTER_TOKEN_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_TAKEOVER_FOR,
  P_VE_EXTEND_LOCK_FOR,
  P_VE_MERGE_LOCKS_FOR,
  P_VE_UNLOCK_EXPIRED_FOR,
  P_WITHDRAW_KING_BUCKET_FOR,
} from '../delegation/permissions.js';
import { getDelegationSession } from '../delegation/sessions.js';

import type { AgentAction, AgentActionResult, AgentTxTelemetry } from './types.js';

import { checkAgentActionSecurity } from './actionSecurity.js';

import type { ExecuteAgentActionParams } from './executor.js';

import {
  buildTxTelemetry,
  getDelegationRequirementForAction,
  pickWalletClientForAction,
  readAllowance,
  simulateOnly,
} from './executorHelpers.js';

export async function executeAgentActionImpl(
  p: ExecuteAgentActionParams,
): Promise<AgentActionResult> {
  const addrMineCore = p.manifest.contracts.MineCore.address as Address;
  const addrFurnace = p.manifest.contracts.Furnace.address as Address;
  const addrRoyalties = p.manifest.contracts.ShareholderRoyalties.address as Address;
  const addrClaimAllHelper = (p.manifest.contracts as any).ClaimAllHelper?.address as
    | Address
    | undefined;
  const addrDelegationHub = (p.manifest.contracts as any).DelegationHub?.address as
    | Address
    | undefined;
  const addrVe = (p.manifest.contracts as any).VeClaimNFT?.address as Address | undefined;
  const addrLpVault = (p.manifest.contracts as any).LpStakingVault7D?.address as
    | Address
    | undefined;
  const addrMarketRouter = (p.manifest.contracts as any).MarketRouter?.address as
    | Address
    | undefined;
  const addrClaimToken = (p.manifest.contracts as any).ClaimToken?.address as Address | undefined;

  const mineCoreAbi = loadAbi({ contractName: 'MineCore', abiNetwork: p.abiNetwork }) as Abi;
  const furnaceAbi = loadAbi({ contractName: 'Furnace', abiNetwork: p.abiNetwork }) as Abi;
  const royaltiesAbi = loadAbi({
    contractName: 'ShareholderRoyalties',
    abiNetwork: p.abiNetwork,
  }) as Abi;
  const claimAllHelperAbi = addrClaimAllHelper
    ? (loadAbi({ contractName: 'ClaimAllHelper', abiNetwork: p.abiNetwork }) as Abi)
    : undefined;
  const veAbi = addrVe
    ? (loadAbi({ contractName: 'VeClaimNFT', abiNetwork: p.abiNetwork }) as Abi)
    : undefined;
  const lpVaultAbi = addrLpVault
    ? (loadAbi({ contractName: 'LpStakingVault7D', abiNetwork: p.abiNetwork }) as Abi)
    : undefined;
  const marketRouterAbi = addrMarketRouter
    ? (loadAbi({ contractName: 'MarketRouter', abiNetwork: p.abiNetwork }) as Abi)
    : undefined;
  const claimTokenAbi = addrClaimToken
    ? (loadAbi({ contractName: 'ClaimToken', abiNetwork: p.abiNetwork }) as Abi)
    : undefined;

  const txSender = pickWalletClientForAction({
    action: p.action,
    publicWalletClient: p.walletClient,
    privateWalletClient: p.privateWalletClient,
    privateRpcMode: p.privateRpcMode,
  });

  if (p.execute && txSender.blocked) {
    return {
      action: p.action,
      simulated: false,
      error: txSender.reason ?? 'Blocked by private RPC policy',
      details: {
        txRoute: txSender.route,
        privateRpcMode: txSender.mode,
      },
    };
  }

  // ------------------------------------------------------------
  // Delegation session preflight (fail-fast with clear errors)
  // ------------------------------------------------------------

  const req = getDelegationRequirementForAction(p.action);

  const secCheck = checkAgentActionSecurity({
    action: p.action,
    execute: p.execute,
    manifest: p.manifest,
    signer: p.account.address as Address,
    security: p.security,
    delegatedUser: req?.user,
  });

  if (!secCheck.ok) {
    return {
      action: p.action,
      simulated: !p.execute,
      error: secCheck.error,
      details: {
        blockedBy: 'securityPolicy',
        ...(secCheck.details ?? {}),
      },
    };
  }
  if (req) {
    if (!addrDelegationHub) {
      return {
        action: p.action,
        simulated: !p.execute,
        error: 'DelegationHub not found in manifest (cannot execute delegated action)',
      };
    }

    const head = await p.publicClient.getBlock({ blockTag: 'latest' });
    const now = head.timestamp;

    const session = await getDelegationSession({
      publicClient: p.publicClient,
      delegationHub: addrDelegationHub,
      user: req.user,
      delegate: p.account.address as Address,
      abiNetwork: p.abiNetwork,
    });

    const active = session.expiry !== 0n && session.expiry >= now;
    const have = session.perms & req.requiredPerms;
    const missing = req.requiredPerms ^ have;

    if (!active || missing !== 0n) {
      const missingNames = missing !== 0n ? describePerms(missing) : [];

      return {
        action: p.action,
        simulated: !p.execute,
        error: !active
          ? `Delegation session inactive/expired (expiry=${session.expiry.toString()}, now=${now.toString()})`
          : `Delegation session missing required perms: ${missingNames.join(', ')}`,
        details: {
          delegationHub: addrDelegationHub,
          user: req.user,
          delegate: p.account.address,
          now: now.toString(),
          session: {
            perms: session.perms.toString(),
            permsNames: describePerms(session.perms),
            expiry: session.expiry.toString(),
            active,
          },
          requiredPerms: req.requiredPerms.toString(),
          requiredPermNames: describePerms(req.requiredPerms),
          missingPerms: missing.toString(),
          missingPermNames: missingNames,
        },
      };
    }
  }

  try {
    switch (p.action.kind) {
      case 'furnace.enterWithEth': {
        const q = await quoteEnterWithEth({
          contracts: p.contracts,
          user: p.account.address as Address,
          ethIn: p.action.ethIn,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithEth',
            args: [
              p.action.targetTokenId,
              p.action.durationSeconds,
              p.action.createAutoMax,
              minVeOut,
            ],
            value: p.action.ethIn,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'enterWithEth',
          args: [
            p.action.targetTokenId,
            p.action.durationSeconds,
            p.action.createAutoMax,
            minVeOut,
          ],
          value: p.action.ethIn,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'furnace.enterWithEthFor': {
        const q = await quoteEnterWithEth({
          contracts: p.contracts,
          user: p.action.user,
          ethIn: p.action.ethIn,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithEthFor',
            args: [
              p.action.user,
              p.action.targetTokenId,
              p.action.durationSeconds,
              p.action.createAutoMax,
              minVeOut,
            ],
            value: p.action.ethIn,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'enterWithEthFor',
          args: [
            p.action.user,
            p.action.targetTokenId,
            p.action.durationSeconds,
            p.action.createAutoMax,
            minVeOut,
          ],
          value: p.action.ethIn,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'furnace.enterWithClaim': {
        const addrClaimToken = (p.manifest.contracts as any).ClaimToken?.address as
          | Address
          | undefined;
        if (!addrClaimToken) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimToken not found in manifest',
          };
        }

        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: addrClaimToken,
          owner: p.account.address as Address,
          spender: addrFurnace,
        });

        if (allowance !== null && allowance < p.action.claimIn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient CLAIM allowance for Furnace (allowance=${allowance.toString()} need=${p.action.claimIn.toString()})`,
            details: {
              token: addrClaimToken,
              owner: p.account.address,
              spender: addrFurnace,
              allowance: allowance.toString(),
              required: p.action.claimIn.toString(),
            },
          };
        }

        const q = await quoteEnterWithClaim({
          contracts: p.contracts,
          user: p.account.address as Address,
          claimIn: p.action.claimIn,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);

        const args = [
          p.action.claimIn,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithClaim',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'enterWithClaim',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'furnace.enterWithClaimFromCallerFor': {
        const addrClaimToken = (p.manifest.contracts as any).ClaimToken?.address as
          | Address
          | undefined;
        if (!addrClaimToken) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimToken not found in manifest',
          };
        }

        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: addrClaimToken,
          owner: p.account.address as Address,
          spender: addrFurnace,
        });

        if (allowance !== null && allowance < p.action.claimIn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient CLAIM allowance for Furnace (allowance=${allowance.toString()} need=${p.action.claimIn.toString()})`,
            details: {
              token: addrClaimToken,
              owner: p.account.address,
              spender: addrFurnace,
              allowance: allowance.toString(),
              required: p.action.claimIn.toString(),
            },
          };
        }

        const q = await quoteEnterWithClaim({
          contracts: p.contracts,
          user: p.action.user,
          claimIn: p.action.claimIn,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);

        const args = [
          p.action.user,
          p.action.claimIn,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithClaimFromCallerFor',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'enterWithClaimFromCallerFor',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'furnace.enterWithToken': {
        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: p.action.tokenIn,
          owner: p.account.address as Address,
          spender: addrFurnace,
        });

        if (allowance !== null && allowance < p.action.amountIn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient token allowance for Furnace (allowance=${allowance.toString()} need=${p.action.amountIn.toString()})`,
            details: {
              token: p.action.tokenIn,
              owner: p.account.address,
              spender: addrFurnace,
              allowance: allowance.toString(),
              required: p.action.amountIn.toString(),
            },
          };
        }

        const q = await quoteEnterWithToken({
          contracts: p.contracts,
          user: p.account.address as Address,
          tokenIn: p.action.tokenIn,
          amountIn: p.action.amountIn,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);

        const args = [
          p.action.tokenIn,
          p.action.amountIn,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithToken',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'enterWithToken',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'furnace.enterWithTokenFromCallerFor': {
        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: p.action.tokenIn,
          owner: p.account.address as Address,
          spender: addrFurnace,
        });

        if (allowance !== null && allowance < p.action.amountIn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient token allowance for Furnace (allowance=${allowance.toString()} need=${p.action.amountIn.toString()})`,
            details: {
              token: p.action.tokenIn,
              owner: p.account.address,
              spender: addrFurnace,
              allowance: allowance.toString(),
              required: p.action.amountIn.toString(),
            },
          };
        }

        const q = await quoteEnterWithToken({
          contracts: p.contracts,
          user: p.action.user,
          tokenIn: p.action.tokenIn,
          amountIn: p.action.amountIn,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);

        const args = [
          p.action.user,
          p.action.tokenIn,
          p.action.amountIn,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithTokenFromCallerFor',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'enterWithTokenFromCallerFor',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'mineCore.takeover': {
        const maxPrice = (p.action.price * 110n) / 100n;
        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'takeover',
            args: [maxPrice],
            value: p.action.price,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'takeover',
          args: [maxPrice],
          value: p.action.price,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'mineCore.takeoverFor': {
        const maxPrice = (p.action.price * 110n) / 100n;
        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'takeoverFor',
            args: [p.action.newKing, maxPrice],
            value: p.action.price,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'takeoverFor',
          args: [p.action.newKing, maxPrice],
          value: p.action.price,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'mineCore.takeoverWithToken': {
        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: p.action.tokenIn,
          owner: p.account.address as Address,
          spender: addrMineCore,
        });

        if (allowance !== null && allowance < p.action.amountIn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient token allowance for MineCore (allowance=${allowance.toString()} need=${p.action.amountIn.toString()})`,
            details: {
              tokenIn: p.action.tokenIn,
              spender: addrMineCore,
              allowance: allowance.toString(),
              needed: p.action.amountIn.toString(),
            },
          };
        }

        const q = await quoteTakeoverWithTokenMinOut({
          contracts: p.contracts,
          tokenIn: p.action.tokenIn,
          amountIn: p.action.amountIn,
          slippageBps: p.action.slippageBps,
        });

        if (q.ethOut < q.takeoverPrice) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Quoted ETH out (${q.ethOut.toString()}) is below takeoverPrice (${q.takeoverPrice.toString()})`,
            details: {
              tokenIn: p.action.tokenIn,
              amountIn: p.action.amountIn.toString(),
              slippageBps: p.action.slippageBps.toString(),
              quoted: {
                ethOut: q.ethOut.toString(),
                takeoverPrice: q.takeoverPrice.toString(),
                minEthOut: q.minEthOut.toString(),
              },
            },
          };
        }

        // Safety: enforce minEthOut >= takeoverPrice. Otherwise a swap could pass minOut
        // but still revert inside MineCore due to insufficient ETH for the takeover price.
        const minEthOut = q.minEthOut < q.takeoverPrice ? q.takeoverPrice : q.minEthOut;
        const maxPrice = (q.takeoverPrice * 110n) / 100n;
        const args = [p.action.tokenIn, p.action.amountIn, minEthOut, maxPrice] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'takeoverWithToken',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                ethOut: q.ethOut.toString(),
                takeoverPrice: q.takeoverPrice.toString(),
                minEthOutQuoted: q.minEthOut.toString(),
              },
              minEthOut: minEthOut.toString(),
              maxPrice: maxPrice.toString(),
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'takeoverWithToken',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              ethOut: q.ethOut.toString(),
              takeoverPrice: q.takeoverPrice.toString(),
              minEthOutQuoted: q.minEthOut.toString(),
            },
            minEthOut: minEthOut.toString(),
            maxPrice: maxPrice.toString(),
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 'mineCore.setCurrentReignRecipients': {
        const currentKing = (await p.publicClient.readContract({
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'currentKing',
          args: [],
        })) as Address;

        if (currentKing.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Only currentKing can setCurrentReignRecipients (currentKing=${currentKing})`,
            details: { currentKing },
          };
        }

        const args = [p.action.ethRecipient, p.action.claimRecipient] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'setCurrentReignRecipients',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: { currentKing, txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'setCurrentReignRecipients',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: { currentKing, txRoute: txSender.route, privateRpcMode: txSender.mode },
        };
      }

      case 'mineCore.setKingAutoLockConfig': {
        if (p.action.durationSeconds > 0xffff_ffffn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `durationSeconds exceeds uint32 max (got=${p.action.durationSeconds.toString()})`,
          };
        }

        const args = [
          p.action.enabled,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'setKingAutoLockConfig',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'setKingAutoLockConfig',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
        };
      }

      case 'mineCore.takeoverWithToken': {
        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: p.action.tokenIn,
          owner: p.account.address as Address,
          spender: addrMineCore,
        });

        if (allowance !== null && allowance < p.action.amountIn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient token allowance for MineCore (allowance=${allowance.toString()} need=${p.action.amountIn.toString()})`,
            details: {
              tokenIn: p.action.tokenIn,
              spender: addrMineCore,
              allowance: allowance.toString(),
              needed: p.action.amountIn.toString(),
            },
          };
        }

        const q = await quoteTakeoverWithTokenMinOut({
          contracts: p.contracts,
          tokenIn: p.action.tokenIn,
          amountIn: p.action.amountIn,
          slippageBps: p.action.slippageBps,
        });

        if (q.ethOut < q.takeoverPrice) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Quoted ETH out (${q.ethOut.toString()}) is below takeoverPrice (${q.takeoverPrice.toString()})`,
            details: {
              tokenIn: p.action.tokenIn,
              amountIn: p.action.amountIn.toString(),
              slippageBps: p.action.slippageBps.toString(),
              quoted: {
                ethOut: q.ethOut.toString(),
                takeoverPrice: q.takeoverPrice.toString(),
                minEthOut: q.minEthOut.toString(),
              },
            },
          };
        }

        // Safety: enforce minEthOut >= takeoverPrice. Otherwise a swap could pass minOut
        // but still revert inside MineCore due to insufficient ETH for the takeover price.
        const minEthOut = q.minEthOut < q.takeoverPrice ? q.takeoverPrice : q.minEthOut;
        const maxPrice = (q.takeoverPrice * 110n) / 100n;
        const args = [p.action.tokenIn, p.action.amountIn, minEthOut, maxPrice] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'takeoverWithToken',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                ethOut: q.ethOut.toString(),
                takeoverPrice: q.takeoverPrice.toString(),
                minEthOutQuoted: q.minEthOut.toString(),
              },
              minEthOut: minEthOut.toString(),
              maxPrice: maxPrice.toString(),
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'takeoverWithToken',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              ethOut: q.ethOut.toString(),
              takeoverPrice: q.takeoverPrice.toString(),
              minEthOutQuoted: q.minEthOut.toString(),
            },
            minEthOut: minEthOut.toString(),
            maxPrice: maxPrice.toString(),
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 'mineCore.setCurrentReignRecipients': {
        const currentKing = (await p.publicClient.readContract({
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'currentKing',
          args: [],
        })) as Address;

        if (currentKing.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Only currentKing can setCurrentReignRecipients (currentKing=${currentKing})`,
            details: { currentKing },
          };
        }

        const args = [p.action.ethRecipient, p.action.claimRecipient] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'setCurrentReignRecipients',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: { currentKing, txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'setCurrentReignRecipients',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: { currentKing, txRoute: txSender.route, privateRpcMode: txSender.mode },
        };
      }

      case 'mineCore.setKingAutoLockConfig': {
        if (p.action.durationSeconds > 0xffff_ffffn) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `durationSeconds exceeds uint32 max (got=${p.action.durationSeconds.toString()})`,
          };
        }

        const args = [
          p.action.enabled,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'setKingAutoLockConfig',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'setKingAutoLockConfig',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
        };
      }

      case 'royalties.claimShareholderEth': {
        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrRoyalties,
            abi: royaltiesAbi,
            functionName: 'claimShareholder',
            args: [0, 0n, 0n, false, 0n],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrRoyalties,
          abi: royaltiesAbi,
          functionName: 'claimShareholder',
          args: [0, 0n, 0n, false, 0n],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'royalties.claimShareholderLock': {
        // Read the current claimable ETH at execution time.
        const claimableEth = (await (p.contracts as any).ShareholderRoyalties.read.claimableEth([
          p.account.address as Address,
        ])) as bigint;

        if (claimableEth === 0n) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'No claimable ETH available to lock',
            details: { claimableEth: '0', txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const q = await quoteEnterWithEth({
          contracts: p.contracts,
          user: p.account.address as Address,
          ethIn: claimableEth,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);
        const args = [
          1,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrRoyalties,
            abi: royaltiesAbi,
            functionName: 'claimShareholder',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              claimableEth: claimableEth.toString(),
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrRoyalties,
          abi: royaltiesAbi,
          functionName: 'claimShareholder',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            claimableEth: claimableEth.toString(),
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 'royalties.setAutoCompoundConfig': {
        const args = [
          p.action.enabled,
          p.action.tokenId,
          p.action.durationSeconds,
          p.action.minCadenceSeconds,
          p.action.minEthToCompound,
        ] as const;

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrRoyalties,
            abi: royaltiesAbi,
            functionName: 'setAutoCompoundConfig',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrRoyalties,
          abi: royaltiesAbi,
          functionName: 'setAutoCompoundConfig',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
        };
      }

      case 'royalties.claimShareholderLock': {
        // Read the current claimable ETH at execution time.
        const claimableEth = (await (p.contracts as any).ShareholderRoyalties.read.claimableEth([
          p.account.address as Address,
        ])) as bigint;

        if (claimableEth === 0n) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'No claimable ETH available to lock',
            details: { claimableEth: '0', txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const q = await quoteEnterWithEth({
          contracts: p.contracts,
          user: p.account.address as Address,
          ethIn: claimableEth,
          targetTokenId: p.action.targetTokenId,
          durationSeconds: p.action.durationSeconds,
          createAutoMax: p.action.createAutoMax,
        });

        const minVeOut = minOutFromBps(q.veOut, p.action.slippageBps);
        const args = [
          1,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          minVeOut,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrRoyalties,
            abi: royaltiesAbi,
            functionName: 'claimShareholder',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              claimableEth: claimableEth.toString(),
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrRoyalties,
          abi: royaltiesAbi,
          functionName: 'claimShareholder',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            claimableEth: claimableEth.toString(),
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
            },
            minVeOut: minVeOut.toString(),
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 'royalties.setAutoCompoundConfig': {
        const args = [
          p.action.enabled,
          p.action.tokenId,
          p.action.durationSeconds,
          p.action.minCadenceSeconds,
          p.action.minEthToCompound,
        ] as const;

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrRoyalties,
            abi: royaltiesAbi,
            functionName: 'setAutoCompoundConfig',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrRoyalties,
          abi: royaltiesAbi,
          functionName: 'setAutoCompoundConfig',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: { txRoute: txSender.route, privateRpcMode: txSender.mode },
        };
      }

      case 'claimAllHelper.claimShareholderForUser': {
        if (!addrClaimAllHelper || !claimAllHelperAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimAllHelper not found in manifest',
          };
        }

        const args = [
          p.action.user,
          p.action.mode,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.minVeOut,
        ];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrClaimAllHelper,
            abi: claimAllHelperAbi,
            functionName: 'claimShareholderForUser',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrClaimAllHelper,
          abi: claimAllHelperAbi,
          functionName: 'claimShareholderForUser',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'claimAllHelper.withdrawKingBalanceForUser': {
        if (!addrClaimAllHelper || !claimAllHelperAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimAllHelper not found in manifest',
          };
        }

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrClaimAllHelper,
            abi: claimAllHelperAbi,
            functionName: 'withdrawKingBalanceForUser',
            args: [p.action.user],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrClaimAllHelper,
          abi: claimAllHelperAbi,
          functionName: 'withdrawKingBalanceForUser',
          args: [p.action.user],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'claimAllHelper.claimAllFor': {
        if (!addrClaimAllHelper || !claimAllHelperAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimAllHelper not found in manifest',
          };
        }

        const args = [
          p.action.user,
          p.action.mode,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.minVeOut,
        ];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrClaimAllHelper,
            abi: claimAllHelperAbi,
            functionName: 'claimAllFor',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrClaimAllHelper,
          abi: claimAllHelperAbi,
          functionName: 'claimAllFor',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'mineCore.withdrawKingBalance': {
        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'withdrawKingBalance',
            args: [],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'withdrawKingBalance',
          args: [],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'mineCore.withdrawRefundBalance': {
        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'withdrawRefundBalance',
            args: [p.action.to],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'withdrawRefundBalance',
          args: [p.action.to],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'marketRouter.listLock': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest (required for approval checks)',
          };
        }

        if (p.action.minClaimOut === 0n) {
          return { action: p.action, simulated: !p.execute, error: 'minClaimOut must be > 0' };
        }
        if (p.action.ttlSeconds === 0n) {
          return { action: p.action, simulated: !p.execute, error: 'ttlSeconds must be > 0' };
        }

        // Safety: listLock is self-only (no delegated entrypoint exists).
        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;
        const expiresAtTime = now + p.action.ttlSeconds;

        // Optional preflight: if trading is paused, listLock will revert.
        const tradingPaused = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'tradingPaused',
        })) as boolean;

        if (tradingPaused) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter trading is paused (cannot listLock)',
          };
        }

        // Listing cooldown preflight.
        const lastActionBlock = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'lastListingActionBlock',
          args: [p.action.tokenId],
        })) as bigint;

        if (head.number <= lastActionBlock) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'Listing cooldown active (must wait at least 1 block between listing state changes).',
            details: {
              tokenId: p.action.tokenId.toString(),
              currentBlockNumber: head.number.toString(),
              lastListingActionBlock: lastActionBlock.toString(),
            },
          };
        }

        // Approval check (MarketRouter must be approved to transfer this veNFT).
        const approved = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getApproved',
          args: [p.action.tokenId],
        })) as Address;

        const approvedForAll = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'isApprovedForAll',
          args: [owner, addrMarketRouter],
        })) as boolean;

        const okApproval =
          approved.toLowerCase() === addrMarketRouter.toLowerCase() || approvedForAll;
        if (!okApproval) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'MarketRouter is not approved to transfer this veNFT. Call VeClaimNFT.approve(MarketRouter, tokenId) or setApprovalForAll(MarketRouter, true).',
            details: {
              tokenId: p.action.tokenId.toString(),
              ve: addrVe,
              owner,
              marketRouter: addrMarketRouter,
              getApproved: approved,
              isApprovedForAll: approvedForAll,
            },
          };
        }

        // Lock info sanity (expiry must be <= lockEnd, lock must not already be listed).
        const lockInfo = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getLockInfo',
          args: [p.action.tokenId],
        })) as any;

        const lockAmount = BigInt(lockInfo?.amount ?? lockInfo?.[0] ?? 0);
        const lockEnd = BigInt(lockInfo?.lockEnd ?? lockInfo?.[1] ?? 0);
        const autoMax = Boolean(lockInfo?.autoMax ?? lockInfo?.[2]);
        const listed = Boolean(lockInfo?.listed ?? lockInfo?.[3]);

        if (lockEnd <= now) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock is expired (lockEnd=${lockEnd.toString()}, now=${now.toString()}).`,
            details: {
              tokenId: p.action.tokenId.toString(),
              lockEnd: lockEnd.toString(),
              now: now.toString(),
            },
          };
        }

        if (listed) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'Lock is already listed/frozen (cannot listLock again).',
            details: { tokenId: p.action.tokenId.toString() },
          };
        }

        if (expiresAtTime > lockEnd) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Listing expiry exceeds lockEnd (expiresAtTime=${expiresAtTime.toString()} > lockEnd=${lockEnd.toString()}). Reduce ttlSeconds or extend the lock first.`,
            details: {
              tokenId: p.action.tokenId.toString(),
              ttlSeconds: p.action.ttlSeconds.toString(),
              now: now.toString(),
              expiresAtTime: expiresAtTime.toString(),
              lockEnd: lockEnd.toString(),
            },
          };
        }

        const sellQuote = await quoteSellLockToFurnace({
          contracts: p.contracts,
          user: owner,
          tokenId: p.action.tokenId,
        });

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'listLock',
            args: [p.action.tokenId, p.action.minClaimOut, expiresAtTime],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              computed: {
                now: now.toString(),
                expiresAtTime: expiresAtTime.toString(),
                lockEnd: lockEnd.toString(),
                lockAmount: lockAmount.toString(),
                autoMax,
                listed,
              },
              minClaimOut: p.action.minClaimOut.toString(),
              furnaceQuote: {
                lockAmount: sellQuote.lockAmount.toString(),
                claimOut: sellQuote.claimOut.toString(),
                spreadBps: sellQuote.spreadBps.toString(),
                lpReward: sellQuote.lpReward.toString(),
                reserveAdd: sellQuote.reserveAdd.toString(),
              },
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'listLock',
          args: [p.action.tokenId, p.action.minClaimOut, expiresAtTime],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            computed: {
              now: now.toString(),
              expiresAtTime: expiresAtTime.toString(),
              lockEnd: lockEnd.toString(),
              lockAmount: lockAmount.toString(),
              autoMax,
              listed,
            },
            minClaimOut: p.action.minClaimOut.toString(),
            furnaceQuote: {
              lockAmount: sellQuote.lockAmount.toString(),
              claimOut: sellQuote.claimOut.toString(),
              spreadBps: sellQuote.spreadBps.toString(),
              lpReward: sellQuote.lpReward.toString(),
              reserveAdd: sellQuote.reserveAdd.toString(),
            },
          },
        };
      }

      case 'marketRouter.delistLock': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        const listing = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'getListing',
          args: [p.action.tokenId],
        })) as any;

        const active = Boolean(listing?.active ?? listing?.[4]);
        const expiresAtTime = BigInt(listing?.expiresAtTime ?? listing?.[3] ?? 0);
        const minClaimOut = BigInt(listing?.minClaimOut ?? listing?.[1] ?? 0);
        const seller = (listing?.seller ?? listing?.[0]) as Address | undefined;

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'Listing is not active (cannot delistLock).',
            details: { tokenId: p.action.tokenId.toString(), seller, active },
          };
        }

        const signer = (p.account.address as Address).toLowerCase();
        if (!seller || seller.toLowerCase() !== signer) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Only the seller (${seller}) can delist this listing.`,
            details: { tokenId: p.action.tokenId.toString(), seller, signer: p.account.address },
          };
        }

        // Cooldown preflight (1-block).
        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const lastActionBlock = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'lastListingActionBlock',
          args: [p.action.tokenId],
        })) as bigint;

        if (head.number <= lastActionBlock) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'Listing cooldown active (must wait at least 1 block between listing state changes).',
            details: {
              tokenId: p.action.tokenId.toString(),
              currentBlockNumber: head.number.toString(),
              lastListingActionBlock: lastActionBlock.toString(),
            },
          };
        }

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'delistLock',
            args: [p.action.tokenId],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              listing: {
                seller,
                minClaimOut: minClaimOut.toString(),
                expiresAtTime: expiresAtTime.toString(),
                active,
              },
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'delistLock',
          args: [p.action.tokenId],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            listing: {
              seller,
              minClaimOut: minClaimOut.toString(),
              expiresAtTime: expiresAtTime.toString(),
              active,
            },
          },
        };
      }

      case 'marketRouter.cancelExpiredListing': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        const listing = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'getListing',
          args: [p.action.tokenId],
        })) as any;

        const active = Boolean(listing?.active ?? listing?.[4]);
        const expiresAtTime = BigInt(listing?.expiresAtTime ?? listing?.[3] ?? 0);
        const minClaimOut = BigInt(listing?.minClaimOut ?? listing?.[1] ?? 0);
        const seller = (listing?.seller ?? listing?.[0]) as Address | undefined;

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'Listing is not active (cannot cancelExpiredListing).',
            details: { tokenId: p.action.tokenId.toString(), seller, active },
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        if (expiresAtTime === 0n || now <= expiresAtTime) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Listing is not expired (expiresAtTime=${expiresAtTime.toString()}, now=${now.toString()}).`,
            details: {
              tokenId: p.action.tokenId.toString(),
              expiresAtTime: expiresAtTime.toString(),
              now: now.toString(),
            },
          };
        }

        // Cooldown preflight (1-block).
        const lastActionBlock = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'lastListingActionBlock',
          args: [p.action.tokenId],
        })) as bigint;

        if (head.number <= lastActionBlock) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'Listing cooldown active (must wait at least 1 block between listing state changes).',
            details: {
              tokenId: p.action.tokenId.toString(),
              currentBlockNumber: head.number.toString(),
              lastListingActionBlock: lastActionBlock.toString(),
            },
          };
        }

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'cancelExpiredListing',
            args: [p.action.tokenId],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              listing: {
                seller,
                minClaimOut: minClaimOut.toString(),
                expiresAtTime: expiresAtTime.toString(),
                active,
              },
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'cancelExpiredListing',
          args: [p.action.tokenId],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            listing: {
              seller,
              minClaimOut: minClaimOut.toString(),
              expiresAtTime: expiresAtTime.toString(),
              active,
            },
          },
        };
      }

      case 'marketRouter.sellLockToFurnace': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest (required for approval checks)',
          };
        }

        // Safety: sellLockToFurnace is self-only (no delegated entrypoint exists).
        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        const approved = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getApproved',
          args: [p.action.tokenId],
        })) as Address;

        const approvedForAll = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'isApprovedForAll',
          args: [owner, addrMarketRouter],
        })) as boolean;

        const okApproval =
          approved.toLowerCase() === addrMarketRouter.toLowerCase() || approvedForAll;
        if (!okApproval) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'MarketRouter is not approved to transfer this veNFT. Call VeClaimNFT.approve(MarketRouter, tokenId) or setApprovalForAll(MarketRouter, true).',
            details: {
              tokenId: p.action.tokenId.toString(),
              ve: addrVe,
              owner,
              marketRouter: addrMarketRouter,
              getApproved: approved,
              isApprovedForAll: approvedForAll,
            },
          };
        }

        const q = await quoteSellLockToFurnace({
          contracts: p.contracts,
          user: owner,
          tokenId: p.action.tokenId,
        });

        const minClaimOut = minOutFromBps(q.claimOut, p.action.slippageBps);

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const deadline = head.timestamp + p.action.deadlineSeconds;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'sellLockToFurnace',
            args: [p.action.tokenId, minClaimOut, deadline],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                lockAmount: q.lockAmount.toString(),
                claimOut: q.claimOut.toString(),
                spreadBps: q.spreadBps.toString(),
                lpReward: q.lpReward.toString(),
                reserveAdd: q.reserveAdd.toString(),
              },
              minClaimOut: minClaimOut.toString(),
              deadline: deadline.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'sellLockToFurnace',
          args: [p.action.tokenId, minClaimOut, deadline],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              lockAmount: q.lockAmount.toString(),
              claimOut: q.claimOut.toString(),
              spreadBps: q.spreadBps.toString(),
              lpReward: q.lpReward.toString(),
              reserveAdd: q.reserveAdd.toString(),
            },
            minClaimOut: minClaimOut.toString(),
            deadline: deadline.toString(),
          },
        };
      }

      case 'marketRouter.sellListedLockToFurnace': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest (required for approval checks)',
          };
        }

        // Self-only safety.
        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        // Listing sanity: ensure listing is active and not expired.
        const listing = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'getListing',
          args: [p.action.tokenId],
        })) as any;

        const active = Boolean(listing?.active ?? listing?.[4]);
        const expiresAtTime = BigInt(listing?.expiresAtTime ?? listing?.[3] ?? 0);
        const minClaimOut = BigInt(listing?.minClaimOut ?? listing?.[1] ?? 0);
        const seller = (listing?.seller ?? listing?.[0]) as Address | undefined;

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;
        const deadline = now + p.action.deadlineSeconds;

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'Listing is not active (cannot sellListedLockToFurnace).',
            details: { tokenId: p.action.tokenId.toString(), seller, active },
          };
        }
        if (expiresAtTime !== 0n && now > expiresAtTime) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Listing expired at ${expiresAtTime.toString()} (now=${now.toString()}). Cancel/refresh the listing before selling.`,
            details: {
              tokenId: p.action.tokenId.toString(),
              seller,
              active,
              expiresAtTime: expiresAtTime.toString(),
              now: now.toString(),
            },
          };
        }

        // Approval check (same as sellLockToFurnace).
        const approved = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getApproved',
          args: [p.action.tokenId],
        })) as Address;

        const approvedForAll = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'isApprovedForAll',
          args: [owner, addrMarketRouter],
        })) as boolean;

        const okApproval =
          approved.toLowerCase() === addrMarketRouter.toLowerCase() || approvedForAll;
        if (!okApproval) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'MarketRouter is not approved to transfer this veNFT. Call VeClaimNFT.approve(MarketRouter, tokenId) or setApprovalForAll(MarketRouter, true).',
            details: {
              tokenId: p.action.tokenId.toString(),
              ve: addrVe,
              owner,
              marketRouter: addrMarketRouter,
              getApproved: approved,
              isApprovedForAll: approvedForAll,
            },
          };
        }

        // Fail-fast slippage sanity: compute expected claimOut from lock info and ensure it meets listing.minClaimOut.
        const lockInfo = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getLockInfo',
          args: [p.action.tokenId],
        })) as any;

        const lockAmount = BigInt(lockInfo?.amount ?? lockInfo?.[0] ?? 0);
        const lockEnd = BigInt(lockInfo?.lockEnd ?? lockInfo?.[1] ?? 0);
        const autoMax = Boolean(lockInfo?.autoMax ?? lockInfo?.[2]);

        const q = (await p.publicClient.readContract({
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'quoteSellLockToFurnaceFromInfo',
          args: [lockAmount, lockEnd, autoMax],
        })) as any;

        const claimOut = BigInt(q?.claimOut ?? q?.[0] ?? 0);
        const spreadBps = BigInt(q?.spreadBps ?? q?.[1] ?? 0);
        const lpReward = BigInt(q?.lpReward ?? q?.[2] ?? 0);
        const reserveAdd = BigInt(q?.reserveAdd ?? q?.[3] ?? 0);

        if (claimOut < minClaimOut) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Quoted claimOut (${claimOut.toString()}) is below listing.minClaimOut (${minClaimOut.toString()}); selling would revert.`,
            details: {
              tokenId: p.action.tokenId.toString(),
              minClaimOut: minClaimOut.toString(),
              quoted: {
                lockAmount: lockAmount.toString(),
                lockEnd: lockEnd.toString(),
                autoMax,
                claimOut: claimOut.toString(),
                spreadBps: spreadBps.toString(),
                lpReward: lpReward.toString(),
                reserveAdd: reserveAdd.toString(),
              },
            },
          };
        }

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'sellListedLockToFurnace',
            args: [p.action.tokenId, deadline],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              listing: {
                seller,
                minClaimOut: minClaimOut.toString(),
                expiresAtTime: expiresAtTime.toString(),
                active,
              },
              quoted: {
                lockAmount: lockAmount.toString(),
                lockEnd: lockEnd.toString(),
                autoMax,
                claimOut: claimOut.toString(),
                spreadBps: spreadBps.toString(),
                lpReward: lpReward.toString(),
                reserveAdd: reserveAdd.toString(),
              },
              deadline: deadline.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'sellListedLockToFurnace',
          args: [p.action.tokenId, deadline],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            listing: {
              seller,
              minClaimOut: minClaimOut.toString(),
              expiresAtTime: expiresAtTime.toString(),
              active,
            },
            quoted: {
              lockAmount: lockAmount.toString(),
              lockEnd: lockEnd.toString(),
              autoMax,
              claimOut: claimOut.toString(),
              spreadBps: spreadBps.toString(),
              lpReward: lpReward.toString(),
              reserveAdd: reserveAdd.toString(),
            },
            deadline: deadline.toString(),
          },
        };
      }

      case 'marketRouter.sellLockToFurnace': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest (required for approval checks)',
          };
        }

        // Safety: sellLockToFurnace is self-only (no delegated entrypoint exists).
        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        const approved = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getApproved',
          args: [p.action.tokenId],
        })) as Address;

        const approvedForAll = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'isApprovedForAll',
          args: [owner, addrMarketRouter],
        })) as boolean;

        const okApproval =
          approved.toLowerCase() === addrMarketRouter.toLowerCase() || approvedForAll;
        if (!okApproval) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'MarketRouter is not approved to transfer this veNFT. Call VeClaimNFT.approve(MarketRouter, tokenId) or setApprovalForAll(MarketRouter, true).',
            details: {
              tokenId: p.action.tokenId.toString(),
              ve: addrVe,
              owner,
              marketRouter: addrMarketRouter,
              getApproved: approved,
              isApprovedForAll: approvedForAll,
            },
          };
        }

        const q = await quoteSellLockToFurnace({
          contracts: p.contracts,
          user: owner,
          tokenId: p.action.tokenId,
        });

        const minClaimOut = minOutFromBps(q.claimOut, p.action.slippageBps);

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const deadline = head.timestamp + p.action.deadlineSeconds;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'sellLockToFurnace',
            args: [p.action.tokenId, minClaimOut, deadline],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              quoted: {
                lockAmount: q.lockAmount.toString(),
                claimOut: q.claimOut.toString(),
                spreadBps: q.spreadBps.toString(),
                lpReward: q.lpReward.toString(),
                reserveAdd: q.reserveAdd.toString(),
              },
              minClaimOut: minClaimOut.toString(),
              deadline: deadline.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'sellLockToFurnace',
          args: [p.action.tokenId, minClaimOut, deadline],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            quoted: {
              lockAmount: q.lockAmount.toString(),
              claimOut: q.claimOut.toString(),
              spreadBps: q.spreadBps.toString(),
              lpReward: q.lpReward.toString(),
              reserveAdd: q.reserveAdd.toString(),
            },
            minClaimOut: minClaimOut.toString(),
            deadline: deadline.toString(),
          },
        };
      }

      case 'marketRouter.sellListedLockToFurnace': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest (required for approval checks)',
          };
        }

        // Self-only safety.
        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        // Listing sanity: ensure listing is active and not expired.
        const listing = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'getListing',
          args: [p.action.tokenId],
        })) as any;

        const active = Boolean(listing?.active ?? listing?.[4]);
        const expiresAtTime = BigInt(listing?.expiresAtTime ?? listing?.[3] ?? 0);
        const minClaimOut = BigInt(listing?.minClaimOut ?? listing?.[1] ?? 0);
        const seller = (listing?.seller ?? listing?.[0]) as Address | undefined;

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;
        const deadline = now + p.action.deadlineSeconds;

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'Listing is not active (cannot sellListedLockToFurnace).',
            details: { tokenId: p.action.tokenId.toString(), seller, active },
          };
        }
        if (expiresAtTime !== 0n && now > expiresAtTime) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Listing expired at ${expiresAtTime.toString()} (now=${now.toString()}). Cancel/refresh the listing before selling.`,
            details: {
              tokenId: p.action.tokenId.toString(),
              seller,
              active,
              expiresAtTime: expiresAtTime.toString(),
              now: now.toString(),
            },
          };
        }

        // Approval check (same as sellLockToFurnace).
        const approved = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getApproved',
          args: [p.action.tokenId],
        })) as Address;

        const approvedForAll = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'isApprovedForAll',
          args: [owner, addrMarketRouter],
        })) as boolean;

        const okApproval =
          approved.toLowerCase() === addrMarketRouter.toLowerCase() || approvedForAll;
        if (!okApproval) {
          return {
            action: p.action,
            simulated: !p.execute,
            error:
              'MarketRouter is not approved to transfer this veNFT. Call VeClaimNFT.approve(MarketRouter, tokenId) or setApprovalForAll(MarketRouter, true).',
            details: {
              tokenId: p.action.tokenId.toString(),
              ve: addrVe,
              owner,
              marketRouter: addrMarketRouter,
              getApproved: approved,
              isApprovedForAll: approvedForAll,
            },
          };
        }

        // Fail-fast slippage sanity: compute expected claimOut from lock info and ensure it meets listing.minClaimOut.
        const lockInfo = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getLockInfo',
          args: [p.action.tokenId],
        })) as any;

        const lockAmount = BigInt(lockInfo?.amount ?? lockInfo?.[0] ?? 0);
        const lockEnd = BigInt(lockInfo?.lockEnd ?? lockInfo?.[1] ?? 0);
        const autoMax = Boolean(lockInfo?.autoMax ?? lockInfo?.[2]);

        const q = (await p.publicClient.readContract({
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'quoteSellLockToFurnaceFromInfo',
          args: [lockAmount, lockEnd, autoMax],
        })) as any;

        const claimOut = BigInt(q?.claimOut ?? q?.[0] ?? 0);
        const spreadBps = BigInt(q?.spreadBps ?? q?.[1] ?? 0);
        const lpReward = BigInt(q?.lpReward ?? q?.[2] ?? 0);
        const reserveAdd = BigInt(q?.reserveAdd ?? q?.[3] ?? 0);

        if (claimOut < minClaimOut) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Quoted claimOut (${claimOut.toString()}) is below listing.minClaimOut (${minClaimOut.toString()}); selling would revert.`,
            details: {
              tokenId: p.action.tokenId.toString(),
              minClaimOut: minClaimOut.toString(),
              quoted: {
                lockAmount: lockAmount.toString(),
                lockEnd: lockEnd.toString(),
                autoMax,
                claimOut: claimOut.toString(),
                spreadBps: spreadBps.toString(),
                lpReward: lpReward.toString(),
                reserveAdd: reserveAdd.toString(),
              },
            },
          };
        }

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'sellListedLockToFurnace',
            args: [p.action.tokenId, deadline],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              listing: {
                seller,
                minClaimOut: minClaimOut.toString(),
                expiresAtTime: expiresAtTime.toString(),
                active,
              },
              quoted: {
                lockAmount: lockAmount.toString(),
                lockEnd: lockEnd.toString(),
                autoMax,
                claimOut: claimOut.toString(),
                spreadBps: spreadBps.toString(),
                lpReward: lpReward.toString(),
                reserveAdd: reserveAdd.toString(),
              },
              deadline: deadline.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'sellListedLockToFurnace',
          args: [p.action.tokenId, deadline],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            listing: {
              seller,
              minClaimOut: minClaimOut.toString(),
              expiresAtTime: expiresAtTime.toString(),
              active,
            },
            quoted: {
              lockAmount: lockAmount.toString(),
              lockEnd: lockEnd.toString(),
              autoMax,
              claimOut: claimOut.toString(),
              spreadBps: spreadBps.toString(),
              lpReward: lpReward.toString(),
              reserveAdd: reserveAdd.toString(),
            },
            deadline: deadline.toString(),
          },
        };
      }

      case 'marketRouter.cancelExpiredBonusTargetEscrow': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        const offer = (await p.publicClient.readContract({
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'getBonusTargetEscrow',
          args: [p.action.offerId],
        })) as any;

        const active = Boolean((offer as any).active ?? (Array.isArray(offer) ? offer[8] : false));
        const buyer = String((offer as any).buyer ?? (Array.isArray(offer) ? offer[0] : ''));
        const fundsRemaining = BigInt(
          (offer as any).fundsRemaining ?? (Array.isArray(offer) ? offer[5] : 0),
        );
        const expiresAt = BigInt((offer as any).expiresAt ?? (Array.isArray(offer) ? offer[7] : 0));

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer not active (offerId=${p.action.offerId.toString()})`,
          };
        }
        if (expiresAt === 0n || now <= expiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer not expired (expiresAt=${expiresAt.toString()}, now=${now.toString()})`,
          };
        }

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'cancelExpiredBonusTargetEscrow',
            args: [p.action.offerId],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              buyer,
              fundsRemaining: fundsRemaining.toString(),
              expiresAt: expiresAt.toString(),
              now: now.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'cancelExpiredBonusTargetEscrow',
          args: [p.action.offerId],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            buyer,
            fundsRemaining: fundsRemaining.toString(),
            expiresAt: expiresAt.toString(),
            now: now.toString(),
          },
        };
      }

      case 'marketRouter.executeAutoFurnace': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        const [tradingPaused, offer, cfg] = (await Promise.all([
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'tradingPaused',
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrow',
            args: [p.action.offerId],
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'bonusTargetConfigs',
            args: [p.action.offerId],
          }),
        ])) as any;

        if (Boolean(tradingPaused)) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter tradingPaused=true (cannot executeAutoFurnace)',
          };
        }

        const active = Boolean((offer as any).active ?? (Array.isArray(offer) ? offer[8] : false));
        const buyer = String(
          (offer as any).buyer ?? (Array.isArray(offer) ? offer[0] : ''),
        ) as Address;
        const durationSeconds = BigInt(
          (offer as any).durationSeconds ?? (Array.isArray(offer) ? offer[2] : 0),
        );
        const createAutoMax = Boolean(
          (offer as any).createAutoMax ?? (Array.isArray(offer) ? offer[3] : false),
        );
        const destinationLockId = BigInt(
          (offer as any).destinationLockId ?? (Array.isArray(offer) ? offer[4] : 0),
        );
        const claimIn = BigInt(
          (offer as any).fundsRemaining ?? (Array.isArray(offer) ? offer[5] : 0),
        );
        const expiresAt = BigInt((offer as any).expiresAt ?? (Array.isArray(offer) ? offer[7] : 0));

        const configured = Boolean(
          (cfg as any).configured ?? (Array.isArray(cfg) ? cfg[2] : false),
        );
        const targetBonusBps = BigInt(
          (cfg as any).targetBonusBps ?? (Array.isArray(cfg) ? cfg[0] : 0),
        );
        const slippageBps = BigInt((cfg as any).slippageBps ?? (Array.isArray(cfg) ? cfg[1] : 0));

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer not active (offerId=${p.action.offerId.toString()})`,
          };
        }
        if (expiresAt !== 0n && now > expiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer expired (expiresAt=${expiresAt.toString()}, now=${now.toString()})`,
          };
        }
        if (!configured) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer not configured (offerId=${p.action.offerId.toString()})`,
          };
        }
        if (claimIn === 0n) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer has no fundsRemaining (offerId=${p.action.offerId.toString()})`,
          };
        }

        // Resolve destination lock eligibility (MarketRouter will fallback to 0 if not eligible).
        const targetEnd = now + durationSeconds;
        let resolvedLockId = destinationLockId;
        let destinationEligible: boolean | null = null;

        if (destinationLockId !== 0n && addrVe && veAbi) {
          destinationEligible = false;
          try {
            const owner = (await p.publicClient.readContract({
              address: addrVe,
              abi: veAbi,
              functionName: 'ownerOf',
              args: [destinationLockId],
            })) as Address;

            if (owner.toLowerCase() === buyer.toLowerCase()) {
              const info = (await p.publicClient.readContract({
                address: addrVe,
                abi: veAbi,
                functionName: 'getLockInfo',
                args: [destinationLockId],
              })) as any;

              const lockEnd = BigInt((info as any).lockEnd ?? (Array.isArray(info) ? info[1] : 0));
              const autoMax = Boolean(
                (info as any).autoMax ?? (Array.isArray(info) ? info[2] : false),
              );
              const listed = Boolean(
                (info as any).listed ?? (Array.isArray(info) ? info[3] : false),
              );

              if (lockEnd > now && !listed && autoMax === createAutoMax && lockEnd <= targetEnd) {
                destinationEligible = true;
              }
            }
          } catch {
            // ignore; destinationEligible remains false
          }

          if (!destinationEligible) {
            resolvedLockId = 0n;
          }
        }

        // Quote the Furnace entry and ensure the expected bonus meets the target.
        let q;
        try {
          q = await quoteEnterWithClaim({
            contracts: p.contracts,
            user: buyer,
            claimIn,
            targetTokenId: resolvedLockId,
            durationSeconds,
            createAutoMax,
          });
        } catch (err) {
          // If quoting against a destination lock fails, fall back to "new lock" quote.
          if (resolvedLockId !== 0n) {
            resolvedLockId = 0n;
            destinationEligible = false;
            q = await quoteEnterWithClaim({
              contracts: p.contracts,
              user: buyer,
              claimIn,
              targetTokenId: resolvedLockId,
              durationSeconds,
              createAutoMax,
            });
          } else {
            throw err;
          }
        }

        if (q.principalClaim === 0n) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'Invalid quote: principalClaim=0',
          };
        }

        const bonusBpsVsPrincipalClaim = (q.bonusClaim * 10_000n) / q.principalClaim;
        if (bonusBpsVsPrincipalClaim < targetBonusBps) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Quoted bonus below target (bonusBpsVsPrincipalClaim=${bonusBpsVsPrincipalClaim.toString()}, targetBonusBps=${targetBonusBps.toString()})`,
            details: {
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
            },
          };
        }

        const minVeOut = minOutFromBps(q.veOut, slippageBps);

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'executeAutoFurnace',
            args: [p.action.offerId],
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              buyer,
              claimIn: claimIn.toString(),
              expiresAt: expiresAt.toString(),
              durationSeconds: durationSeconds.toString(),
              createAutoMax,
              destinationLockId: destinationLockId.toString(),
              resolvedLockId: resolvedLockId.toString(),
              destinationEligible,
              config: {
                targetBonusBps: targetBonusBps.toString(),
                slippageBps: slippageBps.toString(),
                configured,
              },
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
                bonusBpsVsPrincipalClaim: bonusBpsVsPrincipalClaim.toString(),
              },
              minVeOut: minVeOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'executeAutoFurnace',
          args: [p.action.offerId],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            buyer,
            claimIn: claimIn.toString(),
            expiresAt: expiresAt.toString(),
            durationSeconds: durationSeconds.toString(),
            createAutoMax,
            destinationLockId: destinationLockId.toString(),
            resolvedLockId: resolvedLockId.toString(),
            destinationEligible,
            config: {
              targetBonusBps: targetBonusBps.toString(),
              slippageBps: slippageBps.toString(),
              configured,
            },
            quoted: {
              principalClaim: q.principalClaim.toString(),
              bonusClaim: q.bonusClaim.toString(),
              veOut: q.veOut.toString(),
              routeTokenId: q.routeTokenId.toString(),
              bonusBpsVsPrincipalClaim: bonusBpsVsPrincipalClaim.toString(),
            },
            minVeOut: minVeOut.toString(),
          },
        };
      }

      case 'marketRouter.createBonusTargetEscrowWithTarget': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrClaimToken || !claimTokenAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimToken not found in manifest',
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        const BPS_DENOM = 10_000n;

        const discountBps =
          p.action.targetBonusBps === 0n
            ? 0n
            : (p.action.targetBonusBps * BPS_DENOM) / (BPS_DENOM + p.action.targetBonusBps);

        const [tradingPaused, minBudget, maxDiscount] = (await Promise.all([
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'tradingPaused',
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'minBonusTargetEscrowBudget',
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'maxBonusTargetEscrowDiscountBps',
          }),
        ])) as any as [boolean, bigint, bigint];

        if (tradingPaused) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter tradingPaused=true (cannot create offer)',
          };
        }

        if (p.action.budgetClaim < minBudget) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer budget below protocol minimum (budgetClaim=${p.action.budgetClaim.toString()}, min=${minBudget.toString()})`,
            details: {
              minBonusTargetEscrowBudget: minBudget.toString(),
            },
          };
        }

        if (discountBps >= BPS_DENOM || discountBps > maxDiscount) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Computed discountBps out of bounds (discountBps=${discountBps.toString()}, max=${maxDiscount.toString()})`,
            details: {
              targetBonusBps: p.action.targetBonusBps.toString(),
              discountBps: discountBps.toString(),
              maxBonusTargetEscrowDiscountBps: maxDiscount.toString(),
            },
          };
        }

        if (p.action.slippageBps >= BPS_DENOM) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `slippageBps must be < ${BPS_DENOM.toString()} (got ${p.action.slippageBps.toString()})`,
          };
        }

        const allowance = (await p.publicClient.readContract({
          address: addrClaimToken,
          abi: claimTokenAbi,
          functionName: 'allowance',
          args: [p.account.address as Address, addrMarketRouter],
        })) as any as bigint;

        if (allowance < p.action.budgetClaim) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient CLAIM allowance for MarketRouter (allowance=${allowance.toString()}, required=${p.action.budgetClaim.toString()}). Approve ClaimToken -> MarketRouter first.`,
            details: {
              claimToken: addrClaimToken,
              marketRouter: addrMarketRouter,
              allowance: allowance.toString(),
              required: p.action.budgetClaim.toString(),
            },
          };
        }

        // Optional: destination lock sanity checks (ownership + not listed + autoMax match).
        if (p.action.destinationLockId !== 0n && addrVe && veAbi) {
          try {
            const owner = (await p.publicClient.readContract({
              address: addrVe,
              abi: veAbi,
              functionName: 'ownerOf',
              args: [p.action.destinationLockId],
            })) as any as Address;

            if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId not owned by caller (tokenId=${p.action.destinationLockId.toString()}, owner=${owner})`,
              };
            }

            const info = (await p.publicClient.readContract({
              address: addrVe,
              abi: veAbi,
              functionName: 'getLockInfo',
              args: [p.action.destinationLockId],
            })) as any;

            const lockEnd = BigInt((info as any).lockEnd ?? (Array.isArray(info) ? info[1] : 0));
            const autoMax = Boolean(
              (info as any).autoMax ?? (Array.isArray(info) ? info[2] : false),
            );
            const listed = Boolean((info as any).listed ?? (Array.isArray(info) ? info[3] : false));

            if (lockEnd !== 0n && lockEnd <= now) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId is expired (lockEnd=${lockEnd.toString()}, now=${now.toString()})`,
              };
            }
            if (listed) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId is listed/frozen (tokenId=${p.action.destinationLockId.toString()})`,
              };
            }
            if (autoMax !== p.action.createAutoMax) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId autoMax mismatch (lock.autoMax=${String(autoMax)}, offer.createAutoMax=${String(
                  p.action.createAutoMax,
                )})`,
              };
            }
          } catch (_err) {
            // Ignore, let contract revert with canonical reason.
          }
        }

        const args = [
          p.action.targetBonusBps,
          p.action.budgetClaim,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.escrowTtlSeconds,
          p.action.destinationLockId,
          p.action.slippageBps,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'createBonusTargetEscrowWithTarget',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              discountBps: discountBps.toString(),
              minBonusTargetEscrowBudget: minBudget.toString(),
              maxBonusTargetEscrowDiscountBps: maxDiscount.toString(),
              allowance: allowance.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'createBonusTargetEscrowWithTarget',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            discountBps: discountBps.toString(),
            minBonusTargetEscrowBudget: minBudget.toString(),
            maxBonusTargetEscrowDiscountBps: maxDiscount.toString(),
            allowance: allowance.toString(),
          },
        };
      }

      case 'marketRouter.cancelBonusTargetEscrow': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        // Best-effort preflight for clearer errors.
        try {
          const offer = (await p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrow',
            args: [p.action.offerId],
          })) as any;

          const active = Boolean(
            (offer as any).active ?? (Array.isArray(offer) ? offer[8] : false),
          );
          const buyer = String((offer as any).buyer ?? (Array.isArray(offer) ? offer[0] : ''));
          const remaining = BigInt(
            (offer as any).fundsRemaining ?? (Array.isArray(offer) ? offer[5] : 0),
          );

          if (!active) {
            return {
              action: p.action,
              simulated: !p.execute,
              error: `Offer not active (offerId=${p.action.offerId.toString()})`,
            };
          }
          if (buyer && buyer.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
            return {
              action: p.action,
              simulated: !p.execute,
              error: `Not offer buyer (offerId=${p.action.offerId.toString()}, buyer=${buyer})`,
            };
          }

          if (!p.execute) {
            await simulateOnly({
              publicClient: p.publicClient,
              account: p.account,
              address: addrMarketRouter,
              abi: marketRouterAbi,
              functionName: 'cancelBonusTargetEscrow',
              args: [p.action.offerId],
            });
            return {
              action: p.action,
              simulated: true,
              details: { fundsRemaining: remaining.toString() },
            };
          }

          const tx = await simulateAndWrite({
            publicClient: p.publicClient,
            walletClient: txSender.walletClient,
            account: p.account,
            txManager: p.txManager,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'cancelBonusTargetEscrow',
            args: [p.action.offerId],
          });

          return {
            action: p.action,
            simulated: false,
            hash: tx.hash,
            receiptBlockNumber: tx.receipt.blockNumber,
            tx: buildTxTelemetry({ txSender, tx }),
            result: tx.result,
            details: { fundsRemaining: remaining.toString() },
          };
        } catch (_err) {
          // Fallback to simulation/write which will surface canonical revert reason.
        }

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'cancelBonusTargetEscrow',
            args: [p.action.offerId],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'cancelBonusTargetEscrow',
          args: [p.action.offerId],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'marketRouter.extendBonusTargetEscrowExpiry': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        // Preflight: fetch current expiry + max expiry bound for better error messages.
        const [offer, bounds] = (await Promise.all([
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrow',
            args: [p.action.offerId],
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrowExpiryBounds',
            args: [p.action.offerId],
          }),
        ])) as any;

        const active = Boolean((offer as any).active ?? (Array.isArray(offer) ? offer[8] : false));
        const buyer = String((offer as any).buyer ?? (Array.isArray(offer) ? offer[0] : ''));
        const expiresAt = BigInt((offer as any).expiresAt ?? (Array.isArray(offer) ? offer[7] : 0));

        const maxExpiresAt = BigInt(
          (bounds as any).maxExpiresAt ?? (Array.isArray(bounds) ? bounds[2] : 0),
        );

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer not active (offerId=${p.action.offerId.toString()})`,
          };
        }
        if (buyer && buyer.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Not offer buyer (buyer=${buyer})`,
          };
        }
        if (now > expiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer already expired (expiresAt=${expiresAt.toString()}, now=${now.toString()})`,
          };
        }

        const newExpiresAt = now + p.action.ttlSecondsFromNow;
        if (newExpiresAt <= expiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `New expiry must be > current expiry (current=${expiresAt.toString()}, new=${newExpiresAt.toString()})`,
          };
        }
        if (maxExpiresAt !== 0n && newExpiresAt > maxExpiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `New expiry exceeds maxExpiresAt (new=${newExpiresAt.toString()}, max=${maxExpiresAt.toString()})`,
            details: { maxExpiresAt: maxExpiresAt.toString() },
          };
        }

        const args = [p.action.offerId, newExpiresAt] as const;

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'extendBonusTargetEscrowExpiry',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            details: {
              expiresAt: expiresAt.toString(),
              newExpiresAt: newExpiresAt.toString(),
              maxExpiresAt: maxExpiresAt.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'extendBonusTargetEscrowExpiry',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            expiresAt: expiresAt.toString(),
            newExpiresAt: newExpiresAt.toString(),
            maxExpiresAt: maxExpiresAt.toString(),
          },
        };
      }

      case 'marketRouter.createBonusTargetEscrowWithTarget': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }
        if (!addrClaimToken || !claimTokenAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'ClaimToken not found in manifest',
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        const BPS_DENOM = 10_000n;

        const discountBps =
          p.action.targetBonusBps === 0n
            ? 0n
            : (p.action.targetBonusBps * BPS_DENOM) / (BPS_DENOM + p.action.targetBonusBps);

        const [tradingPaused, minBudget, maxDiscount] = (await Promise.all([
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'tradingPaused',
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'minBonusTargetEscrowBudget',
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'maxBonusTargetEscrowDiscountBps',
          }),
        ])) as any as [boolean, bigint, bigint];

        if (tradingPaused) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter tradingPaused=true (cannot create offer)',
          };
        }

        if (p.action.budgetClaim < minBudget) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer budget below protocol minimum (budgetClaim=${p.action.budgetClaim.toString()}, min=${minBudget.toString()})`,
            details: {
              minBonusTargetEscrowBudget: minBudget.toString(),
            },
          };
        }

        if (discountBps >= BPS_DENOM || discountBps > maxDiscount) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Computed discountBps out of bounds (discountBps=${discountBps.toString()}, max=${maxDiscount.toString()})`,
            details: {
              targetBonusBps: p.action.targetBonusBps.toString(),
              discountBps: discountBps.toString(),
              maxBonusTargetEscrowDiscountBps: maxDiscount.toString(),
            },
          };
        }

        if (p.action.slippageBps >= BPS_DENOM) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `slippageBps must be < ${BPS_DENOM.toString()} (got ${p.action.slippageBps.toString()})`,
          };
        }

        const allowance = (await p.publicClient.readContract({
          address: addrClaimToken,
          abi: claimTokenAbi,
          functionName: 'allowance',
          args: [p.account.address as Address, addrMarketRouter],
        })) as any as bigint;

        if (allowance < p.action.budgetClaim) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Insufficient CLAIM allowance for MarketRouter (allowance=${allowance.toString()}, required=${p.action.budgetClaim.toString()}). Approve ClaimToken -> MarketRouter first.`,
            details: {
              claimToken: addrClaimToken,
              marketRouter: addrMarketRouter,
              allowance: allowance.toString(),
              required: p.action.budgetClaim.toString(),
            },
          };
        }

        // Optional: destination lock sanity checks (ownership + not listed + autoMax match).
        if (p.action.destinationLockId !== 0n && addrVe && veAbi) {
          try {
            const owner = (await p.publicClient.readContract({
              address: addrVe,
              abi: veAbi,
              functionName: 'ownerOf',
              args: [p.action.destinationLockId],
            })) as any as Address;

            if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId not owned by caller (tokenId=${p.action.destinationLockId.toString()}, owner=${owner})`,
              };
            }

            const info = (await p.publicClient.readContract({
              address: addrVe,
              abi: veAbi,
              functionName: 'getLockInfo',
              args: [p.action.destinationLockId],
            })) as any;

            const lockEnd = BigInt((info as any).lockEnd ?? (Array.isArray(info) ? info[1] : 0));
            const autoMax = Boolean(
              (info as any).autoMax ?? (Array.isArray(info) ? info[2] : false),
            );
            const listed = Boolean((info as any).listed ?? (Array.isArray(info) ? info[3] : false));

            if (lockEnd !== 0n && lockEnd <= now) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId is expired (lockEnd=${lockEnd.toString()}, now=${now.toString()})`,
              };
            }
            if (listed) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId is listed/frozen (tokenId=${p.action.destinationLockId.toString()})`,
              };
            }
            if (autoMax !== p.action.createAutoMax) {
              return {
                action: p.action,
                simulated: !p.execute,
                error: `destinationLockId autoMax mismatch (lock.autoMax=${String(autoMax)}, offer.createAutoMax=${String(
                  p.action.createAutoMax,
                )})`,
              };
            }
          } catch (_err) {
            // Ignore, let contract revert with canonical reason.
          }
        }

        const args = [
          p.action.targetBonusBps,
          p.action.budgetClaim,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.escrowTtlSeconds,
          p.action.destinationLockId,
          p.action.slippageBps,
        ] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'createBonusTargetEscrowWithTarget',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              discountBps: discountBps.toString(),
              minBonusTargetEscrowBudget: minBudget.toString(),
              maxBonusTargetEscrowDiscountBps: maxDiscount.toString(),
              allowance: allowance.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'createBonusTargetEscrowWithTarget',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            discountBps: discountBps.toString(),
            minBonusTargetEscrowBudget: minBudget.toString(),
            maxBonusTargetEscrowDiscountBps: maxDiscount.toString(),
            allowance: allowance.toString(),
          },
        };
      }

      case 'marketRouter.cancelBonusTargetEscrow': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        // Best-effort preflight for clearer errors.
        try {
          const offer = (await p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrow',
            args: [p.action.offerId],
          })) as any;

          const active = Boolean(
            (offer as any).active ?? (Array.isArray(offer) ? offer[8] : false),
          );
          const buyer = String((offer as any).buyer ?? (Array.isArray(offer) ? offer[0] : ''));
          const remaining = BigInt(
            (offer as any).fundsRemaining ?? (Array.isArray(offer) ? offer[5] : 0),
          );

          if (!active) {
            return {
              action: p.action,
              simulated: !p.execute,
              error: `Offer not active (offerId=${p.action.offerId.toString()})`,
            };
          }
          if (buyer && buyer.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
            return {
              action: p.action,
              simulated: !p.execute,
              error: `Not offer buyer (offerId=${p.action.offerId.toString()}, buyer=${buyer})`,
            };
          }

          if (!p.execute) {
            await simulateOnly({
              publicClient: p.publicClient,
              account: p.account,
              address: addrMarketRouter,
              abi: marketRouterAbi,
              functionName: 'cancelBonusTargetEscrow',
              args: [p.action.offerId],
            });
            return {
              action: p.action,
              simulated: true,
              details: { fundsRemaining: remaining.toString() },
            };
          }

          const tx = await simulateAndWrite({
            publicClient: p.publicClient,
            walletClient: txSender.walletClient,
            account: p.account,
            txManager: p.txManager,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'cancelBonusTargetEscrow',
            args: [p.action.offerId],
          });

          return {
            action: p.action,
            simulated: false,
            hash: tx.hash,
            receiptBlockNumber: tx.receipt.blockNumber,
            tx: buildTxTelemetry({ txSender, tx }),
            result: tx.result,
            details: { fundsRemaining: remaining.toString() },
          };
        } catch (_err) {
          // Fallback to simulation/write which will surface canonical revert reason.
        }

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'cancelBonusTargetEscrow',
            args: [p.action.offerId],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'cancelBonusTargetEscrow',
          args: [p.action.offerId],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'marketRouter.extendBonusTargetEscrowExpiry': {
        if (!addrMarketRouter || !marketRouterAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'MarketRouter not found in manifest',
          };
        }

        const head = await p.publicClient.getBlock({ blockTag: 'latest' });
        const now = head.timestamp;

        // Preflight: fetch current expiry + max expiry bound for better error messages.
        const [offer, bounds] = (await Promise.all([
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrow',
            args: [p.action.offerId],
          }),
          p.publicClient.readContract({
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'getBonusTargetEscrowExpiryBounds',
            args: [p.action.offerId],
          }),
        ])) as any;

        const active = Boolean((offer as any).active ?? (Array.isArray(offer) ? offer[8] : false));
        const buyer = String((offer as any).buyer ?? (Array.isArray(offer) ? offer[0] : ''));
        const expiresAt = BigInt((offer as any).expiresAt ?? (Array.isArray(offer) ? offer[7] : 0));

        const maxExpiresAt = BigInt(
          (bounds as any).maxExpiresAt ?? (Array.isArray(bounds) ? bounds[2] : 0),
        );

        if (!active) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer not active (offerId=${p.action.offerId.toString()})`,
          };
        }
        if (buyer && buyer.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Not offer buyer (buyer=${buyer})`,
          };
        }
        if (now > expiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Offer already expired (expiresAt=${expiresAt.toString()}, now=${now.toString()})`,
          };
        }

        const newExpiresAt = now + p.action.ttlSecondsFromNow;
        if (newExpiresAt <= expiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `New expiry must be > current expiry (current=${expiresAt.toString()}, new=${newExpiresAt.toString()})`,
          };
        }
        if (maxExpiresAt !== 0n && newExpiresAt > maxExpiresAt) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `New expiry exceeds maxExpiresAt (new=${newExpiresAt.toString()}, max=${maxExpiresAt.toString()})`,
            details: { maxExpiresAt: maxExpiresAt.toString() },
          };
        }

        const args = [p.action.offerId, newExpiresAt] as const;

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMarketRouter,
            abi: marketRouterAbi,
            functionName: 'extendBonusTargetEscrowExpiry',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            details: {
              expiresAt: expiresAt.toString(),
              newExpiresAt: newExpiresAt.toString(),
              maxExpiresAt: maxExpiresAt.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMarketRouter,
          abi: marketRouterAbi,
          functionName: 'extendBonusTargetEscrowExpiry',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            expiresAt: expiresAt.toString(),
            newExpiresAt: newExpiresAt.toString(),
            maxExpiresAt: maxExpiresAt.toString(),
          },
        };
      }

      // ------------------------------------------------------------
      // Approvals
      // ------------------------------------------------------------

      case 'erc20.approve': {
        const owner = p.account.address as Address;

        const allowanceBefore = await readAllowance({
          publicClient: p.publicClient,
          token: p.action.token,
          owner,
          spender: p.action.spender,
        });

        const args = [p.action.spender, p.action.amount] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: p.action.token,
            abi: erc20Abi as any,
            functionName: 'approve',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              owner,
              token: p.action.token,
              spender: p.action.spender,
              amount: p.action.amount.toString(),
              allowanceBefore: allowanceBefore === null ? null : allowanceBefore.toString(),
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: p.action.token,
          abi: erc20Abi as any,
          functionName: 'approve',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            owner,
            token: p.action.token,
            spender: p.action.spender,
            amount: p.action.amount.toString(),
            allowanceBefore: allowanceBefore === null ? null : allowanceBefore.toString(),
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 'erc20.ensureAllowance': {
        const owner = p.account.address as Address;

        const allowance = await readAllowance({
          publicClient: p.publicClient,
          token: p.action.token,
          owner,
          spender: p.action.spender,
        });

        if (allowance !== null && allowance >= p.action.minAllowance) {
          return {
            action: p.action,
            simulated: !p.execute,
            details: {
              owner,
              token: p.action.token,
              spender: p.action.spender,
              allowance: allowance.toString(),
              minAllowance: p.action.minAllowance.toString(),
              skipped: true,
            },
          };
        }

        const args = [p.action.spender, p.action.approveAmount] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: p.action.token,
            abi: erc20Abi as any,
            functionName: 'approve',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              owner,
              token: p.action.token,
              spender: p.action.spender,
              allowance: allowance === null ? null : allowance.toString(),
              minAllowance: p.action.minAllowance.toString(),
              approveAmount: p.action.approveAmount.toString(),
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: p.action.token,
          abi: erc20Abi as any,
          functionName: 'approve',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            owner,
            token: p.action.token,
            spender: p.action.spender,
            allowance: allowance === null ? null : allowance.toString(),
            minAllowance: p.action.minAllowance.toString(),
            approveAmount: p.action.approveAmount.toString(),
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 've.approve': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
            details: { tokenId: p.action.tokenId.toString(), owner },
          };
        }

        const currentApproved = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'getApproved',
          args: [p.action.tokenId],
        })) as Address;

        if (currentApproved.toLowerCase() === p.action.spender.toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            details: {
              tokenId: p.action.tokenId.toString(),
              owner,
              spender: p.action.spender,
              alreadyApproved: true,
              getApproved: currentApproved,
            },
          };
        }

        const args = [p.action.spender, p.action.tokenId] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'approve',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              tokenId: p.action.tokenId.toString(),
              owner,
              spender: p.action.spender,
              getApproved: currentApproved,
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'approve',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            tokenId: p.action.tokenId.toString(),
            owner,
            spender: p.action.spender,
            getApproved: currentApproved,
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 've.setApprovalForAll': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const owner = p.account.address as Address;

        const current = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'isApprovedForAll',
          args: [owner, p.action.operator],
        })) as boolean;

        if (current === p.action.approved) {
          return {
            action: p.action,
            simulated: !p.execute,
            details: {
              owner,
              operator: p.action.operator,
              approved: p.action.approved,
              alreadySet: true,
            },
          };
        }

        const args = [p.action.operator, p.action.approved] as const;

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'setApprovalForAll',
            args,
          });

          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              owner,
              operator: p.action.operator,
              approved: p.action.approved,
              wasApproved: current,
              txRoute: txSender.route,
              privateRpcMode: txSender.mode,
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'setApprovalForAll',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            owner,
            operator: p.action.operator,
            approved: p.action.approved,
            wasApproved: current,
            txRoute: txSender.route,
            privateRpcMode: txSender.mode,
          },
        };
      }

      case 'furnace.extendWithBonus': {
        const fqContract = (p.contracts as any)['FurnaceQuoter'];
        if (!fqContract) throw new Error('FurnaceQuoter not found in contracts map');

        let minBonusOut = p.action.minBonusOut;

        if (minBonusOut === 0n) {
          const [, bonusClaim] = (await p.publicClient.readContract({
            address: fqContract.address as Address,
            abi: fqContract.abi,
            functionName: 'quoteExtendWithBonus',
            args: [p.account.address, p.action.tokenId, p.action.durationSeconds],
          })) as readonly [bigint, bigint, bigint];

          minBonusOut = bonusClaim;
        }

        const args = [p.action.tokenId, p.action.durationSeconds, minBonusOut];

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'extendWithBonus',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              minBonusOut: minBonusOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'extendWithBonus',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            minBonusOut: minBonusOut.toString(),
          },
        };
      }

      case 'furnace.extendWithBonusFor': {
        const fqContractFor = (p.contracts as any)['FurnaceQuoter'];
        if (!fqContractFor) throw new Error('FurnaceQuoter not found in contracts map');

        let minBonusOut = p.action.minBonusOut;

        if (minBonusOut === 0n) {
          const [, bonusClaim] = (await p.publicClient.readContract({
            address: fqContractFor.address as Address,
            abi: fqContractFor.abi,
            functionName: 'quoteExtendWithBonus',
            args: [p.action.user, p.action.tokenId, p.action.durationSeconds],
          })) as readonly [bigint, bigint, bigint];

          minBonusOut = bonusClaim;
        }

        const args = [p.action.user, p.action.tokenId, p.action.durationSeconds, minBonusOut];

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'extendWithBonusFor',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              minBonusOut: minBonusOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'extendWithBonusFor',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            minBonusOut: minBonusOut.toString(),
          },
        };
      }

      case 'furnace.mergeLocksWithBonus': {
        // v1.0.0: raw VeClaimNFT.mergeLocks was removed; merges flow through Furnace so
        // the bonus engine and reserve accounting stay consistent with the rest of the
        // economic surface. Self-merge: caller must own both locks.
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const signer = p.account.address as Address;

        const ownerFrom = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.fromTokenId],
        })) as Address;

        const ownerInto = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.intoTokenId],
        })) as Address;

        const okFrom = ownerFrom.toLowerCase() === signer.toLowerCase();
        const okInto = ownerInto.toLowerCase() === signer.toLowerCase();

        if (!okFrom || !okInto) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Cannot merge: both locks must be owned by signer ${signer}. fromTokenId owner=${ownerFrom}, intoTokenId owner=${ownerInto}.`,
          };
        }

        const minBonusOut = p.action.minBonusOut;
        const args = [p.action.fromTokenId, p.action.intoTokenId, minBonusOut];

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'mergeLocksWithBonus',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              minBonusOut: minBonusOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'mergeLocksWithBonus',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            minBonusOut: minBonusOut.toString(),
          },
        };
      }

      case 've.unlock': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        const args = [p.action.tokenId];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'unlock',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'unlock',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 've.setAutoMax': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const owner = (await p.publicClient.readContract({
          address: addrVe,
          abi: veAbi,
          functionName: 'ownerOf',
          args: [p.action.tokenId],
        })) as Address;

        if (owner.toLowerCase() !== (p.account.address as Address).toLowerCase()) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: `Lock tokenId=${p.action.tokenId.toString()} is owned by ${owner}, not signer ${p.account.address}. This action is not delegatable.`,
          };
        }

        const args = [p.action.tokenId, p.action.enabled];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'setAutoMax',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'setAutoMax',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 've.checkpointGlobalState': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'checkpointGlobalState',
            args: [],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'checkpointGlobalState',
          args: [],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 've.checkpointTotalVe': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'checkpointTotalVe',
            args: [],
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'checkpointTotalVe',
          args: [],
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'furnace.mergeLocksWithBonusFor': {
        // v1.0.0: raw VeClaimNFT.mergeLocksForUser was removed; the delegation gate now
        // lives in Furnace.mergeLocksWithBonusFor. Bonus and merged principal both stay
        // with `user` — the delegate cannot redirect value.
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const minBonusOut = p.action.minBonusOut;
        const args = [p.action.user, p.action.fromTokenId, p.action.intoTokenId, minBonusOut];

        if (!p.execute) {
          const result = await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'mergeLocksWithBonusFor',
            args,
          });
          return {
            action: p.action,
            simulated: true,
            result,
            details: {
              minBonusOut: minBonusOut.toString(),
            },
          };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrFurnace,
          abi: furnaceAbi,
          functionName: 'mergeLocksWithBonusFor',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
          details: {
            minBonusOut: minBonusOut.toString(),
          },
        };
      }

      case 've.unlockExpiredForUser': {
        if (!addrVe || !veAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'VeClaimNFT not found in manifest',
          };
        }

        const args = [p.action.user, p.action.tokenId];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrVe,
            abi: veAbi,
            functionName: 'unlockExpiredForUser',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrVe,
          abi: veAbi,
          functionName: 'unlockExpiredForUser',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'mineCore.setKingAutoLockConfigForUser': {
        const args = [
          p.action.user,
          p.action.enabled,
          p.action.targetTokenId,
          p.action.durationSeconds,
          p.action.createAutoMax,
          p.action.minVeOut,
        ];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrMineCore,
            abi: mineCoreAbi,
            functionName: 'setKingAutoLockConfigForUser',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrMineCore,
          abi: mineCoreAbi,
          functionName: 'setKingAutoLockConfigForUser',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'royalties.setAutoCompoundConfigForUser': {
        const args = [
          p.action.user,
          p.action.enabled,
          p.action.tokenId,
          p.action.durationSeconds,
          p.action.minCadenceSeconds,
          p.action.minEthToCompound,
        ];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrRoyalties,
            abi: royaltiesAbi,
            functionName: 'setAutoCompoundConfigForUser',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrRoyalties,
          abi: royaltiesAbi,
          functionName: 'setAutoCompoundConfigForUser',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      case 'lpVault.setAutoCompoundConfigForUser': {
        if (!addrLpVault || !lpVaultAbi) {
          return {
            action: p.action,
            simulated: !p.execute,
            error: 'LpStakingVault7D not found in manifest',
          };
        }

        const args = [p.action.user, p.action.enabled, p.action.tokenId, p.action.durationSeconds];

        if (!p.execute) {
          await simulateOnly({
            publicClient: p.publicClient,
            account: p.account,
            address: addrLpVault,
            abi: lpVaultAbi,
            functionName: 'setAutoCompoundConfigForUser',
            args,
          });
          return { action: p.action, simulated: true };
        }

        const tx = await simulateAndWrite({
          publicClient: p.publicClient,
          walletClient: txSender.walletClient,
          account: p.account,
          txManager: p.txManager,
          address: addrLpVault,
          abi: lpVaultAbi,
          functionName: 'setAutoCompoundConfigForUser',
          args,
        });

        return {
          action: p.action,
          simulated: false,
          hash: tx.hash,
          receiptBlockNumber: tx.receipt.blockNumber,
          tx: buildTxTelemetry({ txSender, tx }),
          result: tx.result,
        };
      }

      default: {
        // Exhaustive check
        const _x: never = p.action;
        return { action: _x, simulated: true, error: 'unknown action' };
      }
    }
  } catch (err) {
    const errorInfo = classifyViemError(err);

    if (err instanceof TxTimeoutError) {
      return {
        action: p.action,
        simulated: !p.execute,
        hash: err.lastHash,
        error: safeErrorString(err.message),
        errorInfo,
        tx: buildTxTelemetry({
          txSender,
          meta: { nonce: err.nonce, attempts: err.hashes.length, hashes: err.hashes as any },
        }),
        details: {
          errorInfo,
          nonce: err.nonce.toString(),
          attempts: err.hashes.length,
          hashes: err.hashes,
        },
      };
    }

    if (err instanceof TxRevertedError) {
      return {
        action: p.action,
        simulated: !p.execute,
        hash: err.hash,
        receiptBlockNumber: err.receipt.blockNumber,
        tx: buildTxTelemetry({ txSender, receipt: err.receipt }),
        error: safeErrorString(err.message),
        errorInfo,
        details: {
          receiptStatus: (err.receipt as any)?.status,
          errorInfo,
        },
      };
    }

    return {
      action: p.action,
      simulated: !p.execute,
      error: safeErrorString(err),
      errorInfo,
    };
  }
}
