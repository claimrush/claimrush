import test from 'node:test';
import assert from 'node:assert/strict';

import { buildClients } from '../src/shared/clients.js';

const PRIVATE_KEY = `0x${'11'.repeat(32)}`;

function baseOpts() {
  return {
    chainId: 8453,
    publicRpcUrl: 'http://127.0.0.1:8545',
    privateRpcUrl: 'http://127.0.0.1:8545',
    privateKey: PRIVATE_KEY,
    publicRpcAuthToken: null,
    privateRpcAuthToken: null,
  };
}

test('keeper clients: malformed numeric transport options fail closed to defaults', () => {
  const clients = buildClients({
    ...baseOpts(),
    publicRpcTimeoutMs: '15oops' as any,
    privateRpcTimeoutMs: '20oops' as any,
    rpcRetryCount: '2oops' as any,
  });

  assert.equal(clients.publicClient.transport.timeout, 15_000);
  assert.equal(clients.walletClient.transport.timeout, 15_000);
  assert.equal(clients.publicClient.transport.retryCount, 0);
  assert.equal(clients.walletClient.transport.retryCount, 0);
});

test('keeper clients: canonical integer-like numeric options are still accepted', () => {
  const clients = buildClients({
    ...baseOpts(),
    chainId: '8453' as any,
    publicRpcTimeoutMs: '25' as any,
    privateRpcTimeoutMs: 30,
    rpcRetryCount: '2' as any,
  });

  assert.equal(clients.chain.id, 8453);
  assert.equal(clients.publicClient.transport.timeout, 25);
  assert.equal(clients.walletClient.transport.timeout, 30);
  assert.equal(clients.publicClient.transport.retryCount, 2);
});

test('keeper clients: chain definition includes canonical multicall3 by default', () => {
  const clients = buildClients(baseOpts());

  // publicClient.multicall() crashes with `Chain does not support contract
  // "multicall3"` if this is missing — and every settlement task (compound-lp,
  // compound-shareholders, listings_discovery, market_discovery) depends on
  // it.  Regression guard for the staging incident where `defineChain` was
  // called without a `contracts` field and Thursday's settlement window
  // would have no-op'd.
  const contracts = (clients.chain as any).contracts;
  assert.ok(contracts?.multicall3, 'chain.contracts.multicall3 must be set');
  assert.equal(
    contracts.multicall3.address.toLowerCase(),
    '0xca11bde05977b3631167028862be2a173976ca11',
  );
});

test('keeper clients: KEEPER_MULTICALL3_ADDRESS override takes precedence', () => {
  const clients = buildClients({
    ...baseOpts(),
    multicall3Address: '0x0000000000000000000000000000000000000042',
    multicall3BlockCreated: 123456,
  });

  const contracts = (clients.chain as any).contracts;
  assert.equal(contracts.multicall3.address, '0x0000000000000000000000000000000000000042');
  assert.equal(contracts.multicall3.blockCreated, 123456);
});

test('keeper clients: empty/whitespace multicall3 override falls back to canonical', () => {
  const clients = buildClients({
    ...baseOpts(),
    multicall3Address: '   ' as any,
  });

  const contracts = (clients.chain as any).contracts;
  assert.equal(
    contracts.multicall3.address.toLowerCase(),
    '0xca11bde05977b3631167028862be2a173976ca11',
  );
});

test('keeper clients: malformed multicall3 override is rejected', () => {
  assert.throws(
    () =>
      buildClients({
        ...baseOpts(),
        multicall3Address: '0xnothex',
      }),
    /KEEPER_MULTICALL3_ADDRESS/,
  );
});

test('keeper clients: malformed chain ids are rejected', () => {
  assert.throws(
    () =>
      buildClients({
        ...baseOpts(),
        chainId: '8453oops' as any,
      }),
    /KEEPER_CHAIN_ID must be a positive safe integer/,
  );

  assert.throws(
    () =>
      buildClients({
        ...baseOpts(),
        chainId: 0,
      }),
    /KEEPER_CHAIN_ID must be a positive safe integer/,
  );
});
