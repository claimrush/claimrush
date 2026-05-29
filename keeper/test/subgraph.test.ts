import test from 'node:test';
import assert from 'node:assert/strict';

import { querySubgraph } from '../src/shared/subgraph.js';

test('keeper subgraph: valid JSON response returns data', async () => {
  const originalFetch = globalThis.fetch;

  try {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ data: { ok: true } }), {
        status: 200,
        headers: { 'content-type': 'application/json; charset=utf-8' },
      })) as typeof fetch;

    const data = await querySubgraph<{ ok: boolean }>('https://example.com/subgraph', '{ ok }');
    assert.deepEqual(data, { ok: true });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('keeper subgraph: redirects fail closed', async () => {
  const originalFetch = globalThis.fetch;

  try {
    globalThis.fetch = (async () =>
      new Response('', {
        status: 302,
        headers: { location: 'https://login.example.com' },
      })) as typeof fetch;

    await assert.rejects(
      () => querySubgraph('https://example.com/subgraph', '{ ok }'),
      /subgraph HTTP 302/,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('keeper subgraph: non-JSON success bodies are rejected', async () => {
  const originalFetch = globalThis.fetch;

  try {
    globalThis.fetch = (async () =>
      new Response('<html>nope</html>', {
        status: 200,
        headers: { 'content-type': 'text/html; charset=utf-8' },
      })) as typeof fetch;

    await assert.rejects(
      () => querySubgraph('https://example.com/subgraph', '{ ok }'),
      /subgraph unexpected content-type/,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('keeper subgraph: oversized success bodies are rejected before parse', async () => {
  const originalFetch = globalThis.fetch;

  try {
    globalThis.fetch = (async () =>
      new Response(' '.repeat(2_000_001), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })) as typeof fetch;

    await assert.rejects(
      () => querySubgraph('https://example.com/subgraph', '{ ok }'),
      /subgraph response exceeded max size/,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});
