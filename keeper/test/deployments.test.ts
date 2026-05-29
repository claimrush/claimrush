import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  getContractAddress,
  getContractStartBlock,
  loadDeploymentManifest,
  normalizeDeploymentManifest,
  zeroAddress,
} from '../src/shared/deployments.js';

test('deployment manifest loader normalizes valid contract values', () => {
  const manifest = normalizeDeploymentManifest({
    chainId: 8453,
    contracts: {
      MineCore: {
        address: '0x1111111111111111111111111111111111111111',
        startBlock: '0x2a',
      },
    },
    extra: { preserved: true },
  });

  assert.equal(manifest.chainId, 8453);
  assert.equal(
    getContractAddress(manifest, 'MineCore'),
    '0x1111111111111111111111111111111111111111',
  );
  assert.equal(getContractStartBlock(manifest, 'MineCore'), 42);
  assert.deepEqual((manifest as any).extra, { preserved: true });
});

test('deployment manifest loader rejects poisoned contract keys and invalid chain ids', () => {
  assert.throws(
    () =>
      normalizeDeploymentManifest(
        JSON.parse(`{
          "chainId": 8453,
          "contracts": {
            "__proto__": {
              "address": "0x1111111111111111111111111111111111111111",
              "startBlock": 1
            }
          }
        }`),
      ),
    /illegal key '__proto__'/,
  );

  assert.throws(
    () =>
      normalizeDeploymentManifest({
        chainId: 8453.5,
        contracts: {},
      }),
    /deployment manifest\.chainId: expected positive safe integer/,
  );
});

test('deployment manifest accessors degrade safely on malformed contract fields', () => {
  const manifest = normalizeDeploymentManifest({
    chainId: 8453,
    contracts: {
      MineCore: {
        address: 'not-an-address',
        startBlock: '123oops',
      },
      ClaimToken: {
        address: '0x2222222222222222222222222222222222222222',
        startBlock: '0x2ag',
      },
    },
  });

  assert.equal(getContractAddress(manifest, 'MineCore'), zeroAddress());
  assert.equal(getContractStartBlock(manifest, 'MineCore'), 0);
  assert.equal(getContractStartBlock(manifest, 'ClaimToken'), 0);
});

test('deployment manifest file load applies normalization', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-deployments-'));
  const deploymentsDir = path.join(tmpDir, 'deployments');
  fs.mkdirSync(deploymentsDir, { recursive: true });

  try {
    fs.writeFileSync(
      path.join(deploymentsDir, 'base_mainnet.json'),
      JSON.stringify({
        chainId: 8453,
        contracts: {
          MineCore: {
            address: '0x1111111111111111111111111111111111111111',
            startBlock: '123',
          },
        },
      }),
      'utf8',
    );

    const loaded = loadDeploymentManifest({
      repoRoot: tmpDir,
      deployment: 'base_mainnet',
    });

    assert.equal(getContractStartBlock(loaded.manifest, 'MineCore'), 123);
    assert.equal(
      getContractAddress(loaded.manifest, 'MineCore'),
      '0x1111111111111111111111111111111111111111',
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('deployment manifest file load rejects directory and oversized inputs', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-deployments-'));
  const deploymentsDir = path.join(tmpDir, 'deployments');
  fs.mkdirSync(deploymentsDir, { recursive: true });

  try {
    const dirDeploymentPath = path.join(deploymentsDir, 'bad_dir.json');
    fs.mkdirSync(dirDeploymentPath);
    assert.throws(
      () =>
        loadDeploymentManifest({
          repoRoot: tmpDir,
          deployment: 'bad_dir',
        }),
      /not a regular file/,
    );

    fs.writeFileSync(
      path.join(deploymentsDir, 'oversized.json'),
      JSON.stringify({
        chainId: 8453,
        contracts: {
          MineCore: {
            address: '0x1111111111111111111111111111111111111111',
            startBlock: 1,
          },
        },
        padding: 'x'.repeat(600_000),
      }),
      'utf8',
    );

    assert.throws(
      () =>
        loadDeploymentManifest({
          repoRoot: tmpDir,
          deployment: 'oversized',
        }),
      /too large/,
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
