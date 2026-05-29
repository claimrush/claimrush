import { Address, BigDecimal, BigInt, Bytes, dataSource } from '@graphprotocol/graph-ts';

import { ChainlinkAggregator } from '../generated/VeClaimNFT/ChainlinkAggregator';
import { ClaimToken } from '../generated/VeClaimNFT/ClaimToken';
import { ClaimWethPool } from '../generated/VeClaimNFT/ClaimWethPool';
import { EntryTokenRegistry, TokenPricingSnapshot } from '../generated/schema';

import { PROTOCOL_ID, isZeroAddressBytes, loadOrCreateProtocol } from './protocol';

// One whole CLAIM token expressed in wei (CLAIM is 1e18-decimal).
const ONE_CLAIM_WEI = BigInt.fromString('1000000000000000000');
const ONE_CLAIM_WEI_DECIMAL = ONE_CLAIM_WEI.toBigDecimal();

// 30-minute TWAP granularity passed to Aerodrome v2 `Pool.quote(...)`.
// `granularity = 1` averages over the single most-recent 30-minute observation.
const AERODROME_TWAP_GRANULARITY = BigInt.fromI32(1);

// Chainlink ETH/USD feed on Base mainnet emits answers with 8 decimals.
// The same convention holds for every Chainlink USD feed; if a future deploy
// targets a non-Base chain with a different price-feed family, this denominator
// (and `chainlinkEthUsdFeed` below) need a per-network branch.
const CHAINLINK_USD_DECIMALS_DENOM = BigDecimal.fromString('100000000');

// Stale-feed gate. Mirrors `frontend/src/lib/infoSurfaces.ts::MAX_ETH_USD_FEED_AGE_SECONDS`
// and the contract-side constant referenced in the subgraph-schema spec. Anything
// older than this writes `ethUsd` and `ethUsdUpdatedAt` as null so downstream
// consumers cannot quote USD against a stale oracle.
const MAX_ETH_USD_FEED_AGE_SECONDS = BigInt.fromI32(7200);

/**
 * Pinned Chainlink ETH/USD feed addresses keyed off the data-source network.
 * MUST match `deployments/<network>.json :: chainlink.ethUsdFeed.address`.
 *
 * Returns `null` on networks where the deployment manifest pins the feed to
 * the zero address (base-sepolia / local), which the schema spec treats as
 * "USD disabled" — `ethUsd` and `ethUsdUpdatedAt` stay null in that mode.
 */
function chainlinkEthUsdFeed(): Address | null {
  const net = dataSource.network();
  if (net == 'base') {
    return Address.fromString('0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70');
  }
  return null;
}

/**
 * Refresh the singleton `TokenPricingSnapshot(id:"1")` fields the
 * `/api/stats/protocol` route consumes.
 *
 * Five paired surfaces, all read at the current block:
 *
 *   - `totalSupplyWei`    = ClaimToken.totalSupply()
 *   - `lockedSupplyWei`   = ClaimToken.balanceOf(VeClaimNFT)
 *   - `claimEthTwap30m`   = canonical CLAIM/WETH pool, 30-minute TWAP (ETH per 1 CLAIM)
 *   - `ethUsd`            = Chainlink ETH/USD `latestRoundData().answer / 1e8`
 *   - `ethUsdUpdatedAt`   = Chainlink ETH/USD `latestRoundData().updatedAt`
 *
 * The two supply fields are paired so `circulating = total − locked` stays
 * non-negative across a snapshot boundary. The two USD fields are paired so
 * stale-feed gating writes both nulls together.
 *
 * Skipped entirely on the `local` network: Anvil archive RPCs trip
 * `BlockOutOfRangeError` on retroactive `eth_call`, which graph-node
 * surfaces as an unrecoverable infinite-retry loop.
 */
export function refreshTokenPricingSnapshot(
  veClaimNftAddress: Address,
  blockNumber: BigInt,
  blockTimestamp: BigInt,
): void {
  if (dataSource.network() == 'local') return;

  const protocol = loadOrCreateProtocol(blockNumber);
  const claimTokenAddrBytes = protocol.claimToken;

  // The EntryTokenRegistry wiring event fills `protocol.claimToken` the
  // first time a registry binds to MineCore/Furnace. Until then no contract
  // read is meaningful, so skip silently. The next lock event after wiring
  // re-attempts the refresh.
  if (isZeroAddressBytes(claimTokenAddrBytes)) return;

  const claimTokenAddr = Address.fromBytes(claimTokenAddrBytes as Bytes);
  const claim = ClaimToken.bind(claimTokenAddr);

  let snapshot = TokenPricingSnapshot.load(PROTOCOL_ID);
  if (snapshot == null) {
    snapshot = new TokenPricingSnapshot(PROTOCOL_ID);
  }

  let touched = false;

  // --------------------------------------------------------------------------
  // Supply pair: totalSupplyWei + lockedSupplyWei
  // --------------------------------------------------------------------------
  const totalSupplyResult = claim.try_totalSupply();
  const lockedSupplyResult = claim.try_balanceOf(veClaimNftAddress);

  if (!totalSupplyResult.reverted) {
    snapshot.totalSupplyWei = totalSupplyResult.value;
    touched = true;
  }
  if (!lockedSupplyResult.reverted) {
    snapshot.lockedSupplyWei = lockedSupplyResult.value;
    touched = true;
  }

  // --------------------------------------------------------------------------
  // CLAIM/WETH TWAP: claimEthTwap30m
  // --------------------------------------------------------------------------
  // Resolved indirectly through `EntryTokenRegistry.wethClaimPool` so the
  // pool address stays a deployment-config concern (no subgraph constant).
  // Falls back to `quoteOut` for `TestnetSwapPool` on Sepolia, which exposes
  // a spot read instead of the Aerodrome v2 30-minute TWAP path.
  const registryAddrBytesNullable = protocol.entryTokenRegistry;
  if (registryAddrBytesNullable !== null && !isZeroAddressBytes(registryAddrBytesNullable as Bytes)) {
    const registryAddrBytes = registryAddrBytesNullable as Bytes;
    const registry = EntryTokenRegistry.load(registryAddrBytes.toHexString());
    if (registry != null) {
      const poolAddrBytes = registry.wethClaimPool;
      if (poolAddrBytes !== null && !isZeroAddressBytes(poolAddrBytes as Bytes)) {
        const pool = ClaimWethPool.bind(Address.fromBytes(poolAddrBytes as Bytes));

        let amountOut: BigInt | null = null;
        const aerodromeQuote = pool.try_quote(
          claimTokenAddr,
          ONE_CLAIM_WEI,
          AERODROME_TWAP_GRANULARITY,
        );
        if (!aerodromeQuote.reverted) {
          amountOut = aerodromeQuote.value;
        } else {
          const testnetQuote = pool.try_quoteOut(claimTokenAddr, ONE_CLAIM_WEI);
          if (!testnetQuote.reverted) {
            amountOut = testnetQuote.value;
          }
        }

        if (amountOut !== null && (amountOut as BigInt).gt(BigInt.zero())) {
          snapshot.claimEthTwap30m = (amountOut as BigInt).toBigDecimal().div(ONE_CLAIM_WEI_DECIMAL);
        } else {
          snapshot.claimEthTwap30m = null;
        }
        touched = true;
      }
    }
  }

  // --------------------------------------------------------------------------
  // Chainlink ETH/USD pair: ethUsd + ethUsdUpdatedAt
  // --------------------------------------------------------------------------
  // Always write both fields together — either both as fresh values, or both
  // as null. The schema spec treats them as a single signal: if either side
  // is missing the consumer treats USD displays as unsafe.
  const feedAddr = chainlinkEthUsdFeed();
  if (feedAddr !== null) {
    const aggregator = ChainlinkAggregator.bind(feedAddr as Address);
    const latest = aggregator.try_latestRoundData();
    if (!latest.reverted) {
      const answer = latest.value.getAnswer();
      const feedUpdatedAt = latest.value.getUpdatedAt();
      const age = blockTimestamp.minus(feedUpdatedAt);
      if (
        answer.gt(BigInt.zero()) &&
        feedUpdatedAt.gt(BigInt.zero()) &&
        age.le(MAX_ETH_USD_FEED_AGE_SECONDS)
      ) {
        snapshot.ethUsd = answer.toBigDecimal().div(CHAINLINK_USD_DECIMALS_DENOM);
        snapshot.ethUsdUpdatedAt = feedUpdatedAt;
      } else {
        snapshot.ethUsd = null;
        snapshot.ethUsdUpdatedAt = null;
      }
      touched = true;
    }
  }

  if (touched) {
    snapshot.updatedAt = blockTimestamp;
    snapshot.save();
  }
}
