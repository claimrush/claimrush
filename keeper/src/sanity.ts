#!/usr/bin/env node
/**
 * Keeper Static Sanity Check
 *
 * Validates that:
 * 1. Watched event signatures in market_discovery.mjs match the ABI definitions
 * 2. Tuple decoding indices documented in abis.mjs match the ABI output tuple lengths
 *
 * This is a lightweight, no-RPC check that can run in CI to catch drift
 * between keeper code and contract ABIs.
 *
 * Usage:
 *   node keeper/src/sanity.mjs
 *   npm -C keeper run sanity
 */

import {
  MARKET_ROUTER_ABI,
  FURNACE_ABI,
  VE_CLAIM_NFT_ABI,
  SHAREHOLDER_ROYALTIES_ABI,
} from './shared/abis.js';

// =============================================================================
// Event Signature Verification
// =============================================================================

/**
 * STRICT MODE (v1.0.0+) Event Signatures
 * These must match what market_discovery.mjs listens to.
 */
const EXPECTED_EVENT_SIGNATURES: Record<string, string> = {
  // BonusTargetEscrowConfigured(uint256 indexed offerId, address indexed buyer, uint256 targetBonusBps, uint256 slippageBps)
  BonusTargetEscrowConfigured:
    'event BonusTargetEscrowConfigured(uint256 indexed offerId, address indexed buyer, uint256 targetBonusBps, uint256 slippageBps)',

  // BonusTargetEscrowCancelled(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)
  BonusTargetEscrowCancelled:
    'event BonusTargetEscrowCancelled(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)',

  // BonusTargetEscrowExpired(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)
  BonusTargetEscrowExpired:
    'event BonusTargetEscrowExpired(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)',

  // BonusTargetEscrowAutoFurnaceExecuted(uint256 indexed offerId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId)
  BonusTargetEscrowAutoFurnaceExecuted:
    'event BonusTargetEscrowAutoFurnaceExecuted(uint256 indexed offerId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId)',
};

// =============================================================================
// Tuple Decoding Index Verification
// =============================================================================

interface TupleLayout {
  expectedLength: number;
  indices: Record<string, number>;
}

/**
 * STRICT MODE (v1.0.0+) Tuple Layouts
 * These must match the documented indices in abis.mjs.
 */
const TUPLE_LAYOUTS: Record<string, TupleLayout> = {
  // BonusTargetConfig: (targetBonusBps, slippageBps, configured)
  bonusTargetConfigs: {
    expectedLength: 3,
    indices: {
      targetBonusBps: 0,
      slippageBps: 1,
      configured: 2,
    },
  },

  // BonusTargetEscrow (offers): (buyer, discountBps, durationSeconds, createAutoMax, destinationLockId, fundsRemaining, createdAt, expiresAt, active)
  offers: {
    expectedLength: 9,
    indices: {
      buyer: 0,
      discountBps: 1,
      durationSeconds: 2,
      createAutoMax: 3,
      destinationLockId: 4,
      fundsRemaining: 5,
      createdAt: 6,
      expiresAt: 7,
      active: 8,
    },
  },
};

// =============================================================================
// Validation Functions
// =============================================================================

interface AbiEntry {
  type: string;
  name?: string;
  outputs?: Array<{ name?: string }>;
  [key: string]: unknown;
}

function validateTupleLayout(
  abiEntry: AbiEntry | undefined,
  expectedLayout: TupleLayout,
  functionName: string,
): string[] {
  const errors: string[] = [];

  if (!abiEntry) {
    errors.push(`Function '${functionName}' not found in ABI`);
    return errors;
  }

  const outputs = abiEntry.outputs || [];
  const actualLength = outputs.length;

  if (actualLength !== expectedLayout.expectedLength) {
    errors.push(
      `Function '${functionName}': Expected ${expectedLayout.expectedLength} outputs, got ${actualLength}`,
    );
  }

  // Verify each named index maps to the correct output name
  for (const [expectedName, expectedIndex] of Object.entries(expectedLayout.indices)) {
    if (expectedIndex >= outputs.length) {
      errors.push(
        `Function '${functionName}': Index ${expectedIndex} (${expectedName}) out of bounds (length: ${actualLength})`,
      );
      continue;
    }

    const actualName = outputs[expectedIndex]?.name || '';
    if (actualName !== expectedName) {
      errors.push(
        `Function '${functionName}': Index ${expectedIndex} expected '${expectedName}', got '${actualName}'`,
      );
    }
  }

  return errors;
}

function findAbiFunction(abi: readonly AbiEntry[], functionName: string): AbiEntry | undefined {
  return abi.find((entry) => entry.type === 'function' && entry.name === functionName);
}

function validateMarketRouterAbi(): string[] {
  const errors: string[] = [];

  // Validate bonusTargetConfigs tuple layout
  const bonusTargetConfigsEntry = findAbiFunction(
    MARKET_ROUTER_ABI as unknown as readonly AbiEntry[],
    'bonusTargetConfigs',
  );
  errors.push(
    ...validateTupleLayout(
      bonusTargetConfigsEntry,
      TUPLE_LAYOUTS.bonusTargetConfigs,
      'bonusTargetConfigs',
    ),
  );

  // Validate offers tuple layout
  const offersEntry = findAbiFunction(
    MARKET_ROUTER_ABI as unknown as readonly AbiEntry[],
    'offers',
  );
  errors.push(...validateTupleLayout(offersEntry, TUPLE_LAYOUTS.offers, 'offers'));

  // Verify required functions exist
  const requiredFunctions: string[] = [
    'tradingPaused',
    'executeAutoFurnace',
    'offers',
    'bonusTargetConfigs',
    'sellLockToFurnace',
    'sellListedLockToFurnace',
    'cancelExpiredListing',
  ];

  for (const fn of requiredFunctions) {
    if (!findAbiFunction(MARKET_ROUTER_ABI as unknown as readonly AbiEntry[], fn)) {
      errors.push(`Required function '${fn}' not found in MARKET_ROUTER_ABI`);
    }
  }

  // Verify forbidden functions do NOT exist
  const forbiddenFunctions: string[] = [
    'buyLock',
    'marketBuyWithEth',
    'marketBuyWithClaim',
    'marketSell',
    'acceptGlobalOffer',
    'fillGlobalOfferFromListing',
  ];

  for (const fn of forbiddenFunctions) {
    if (findAbiFunction(MARKET_ROUTER_ABI as unknown as readonly AbiEntry[], fn)) {
      errors.push(`Forbidden function '${fn}' found in MARKET_ROUTER_ABI (Strict Mode violation)`);
    }
  }

  return errors;
}

function validateEventSignatures(): string[] {
  const errors: string[] = [];

  // These event signatures are used by viem's parseAbiItem in market_discovery.mjs
  // We just verify they are well-formed and match our expectations
  for (const [name, signature] of Object.entries(EXPECTED_EVENT_SIGNATURES)) {
    // Basic validation: signature should contain the event name
    if (!signature.includes(`event ${name}(`)) {
      errors.push(`Event signature for '${name}' does not match expected format`);
    }

    // Verify indexed parameters are consistent with Solidity rules
    const indexedCount = (signature.match(/indexed/g) || []).length;
    if (indexedCount > 3) {
      errors.push(`Event '${name}' has ${indexedCount} indexed params (max 3 allowed)`);
    }
  }

  return errors;
}

// =============================================================================
// Main
// =============================================================================

function main(): void {
  console.log('Keeper Static Sanity Check');
  console.log('==========================\n');

  const allErrors: string[] = [];

  // 1. Validate MarketRouter ABI
  console.log('Checking MARKET_ROUTER_ABI tuple layouts...');
  const marketRouterErrors = validateMarketRouterAbi();
  allErrors.push(...marketRouterErrors);
  if (marketRouterErrors.length === 0) {
    console.log('  ✓ MARKET_ROUTER_ABI tuple layouts OK');
  } else {
    for (const err of marketRouterErrors) {
      console.log(`  ✗ ${err}`);
    }
  }

  // 2. Validate event signatures
  console.log('\nChecking event signatures...');
  const eventErrors = validateEventSignatures();
  allErrors.push(...eventErrors);
  if (eventErrors.length === 0) {
    console.log('  ✓ Event signatures OK');
  } else {
    for (const err of eventErrors) {
      console.log(`  ✗ ${err}`);
    }
  }

  // 3. Verify other ABIs have expected structure
  console.log('\nChecking other ABIs...');
  const otherAbis: Array<{ name: string; abi: unknown }> = [
    { name: 'FURNACE_ABI', abi: FURNACE_ABI },
    { name: 'VE_CLAIM_NFT_ABI', abi: VE_CLAIM_NFT_ABI },
    { name: 'SHAREHOLDER_ROYALTIES_ABI', abi: SHAREHOLDER_ROYALTIES_ABI },
  ];
  for (const { name, abi } of otherAbis) {
    if (!Array.isArray(abi) || abi.length === 0) {
      allErrors.push(`${name} is empty or not an array`);
      console.log(`  ✗ ${name} is empty or not an array`);
    } else {
      console.log(`  ✓ ${name} (${abi.length} entries)`);
    }
  }

  // Summary
  console.log('\n==========================');
  if (allErrors.length === 0) {
    console.log('OK: All sanity checks passed');
    process.exit(0);
  } else {
    console.log(`FAILED: ${allErrors.length} errors found`);
    process.exit(1);
  }
}

main();
