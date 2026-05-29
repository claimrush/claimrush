import test from 'node:test';
import assert from 'node:assert/strict';

import { postAlert } from '../src/shared/alert.js';

test('keeper alert: uses manual redirect mode', async () => {
  const originalFetch = globalThis.fetch;
  const seen = {
    redirect: undefined as string | undefined,
    method: undefined as string | undefined,
  };

  globalThis.fetch = (async (_input: string | URL | Request, init?: unknown) => {
    const requestInit = (init as { redirect?: string; method?: string } | undefined) ?? {};
    seen.redirect = requestInit.redirect;
    seen.method = requestInit.method;
    return new Response('{}', {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }) as typeof fetch;

  try {
    const result = await postAlert(
      'https://alerts.example.test/hook',
      { ok: true },
      { dedupeWindowMs: 0 },
    );
    assert.equal(result.sent, true);
    assert.equal(seen.redirect, 'manual');
    assert.equal(seen.method, 'POST');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('keeper alert: bounds oversized error bodies before logging', async () => {
  const originalFetch = globalThis.fetch;
  const logs: string[] = [];

  globalThis.fetch = (async () =>
    new Response('x'.repeat(10_000), {
      status: 502,
      headers: { 'content-type': 'text/plain; charset=utf-8' },
    })) as typeof fetch;

  try {
    const result = await postAlert(
      'https://alerts.example.test/hook',
      { ok: true },
      { dedupeWindowMs: 0, log: (msg) => logs.push(msg) },
    );

    assert.equal(result.sent, false);
    assert.equal(result.status, 502);
    assert.equal(logs.length, 1);
    assert.match(logs[0] ?? '', /alert webhook HTTP 502:/);
    assert.match(logs[0] ?? '', /<body_too_large>/);
    assert.ok((logs[0] ?? '').length < 400);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// Regression: the dedupe key MUST distinguish alerts that share type/action/
// deployment but carry different `message` fields. Before the pass-2 fix the
// key only considered `error`/`reason`, so two distinct keeper failures with
// only a `message` would collapse into one and silently drop the second.
test('keeper alert: dedupes by message when error/reason are absent', async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;

  globalThis.fetch = (async () => {
    calls += 1;
    return new Response('{}', {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }) as typeof fetch;

  try {
    // Identical payloads inside a 60s dedupe window: second call MUST be deduped.
    const a1 = await postAlert(
      'https://alerts.example.test/hook',
      { type: 'keeper-fault', action: 'poll', deployment: 'base', message: 'rpc timeout' },
      { dedupeWindowMs: 60_000 },
    );
    const a2 = await postAlert(
      'https://alerts.example.test/hook',
      { type: 'keeper-fault', action: 'poll', deployment: 'base', message: 'rpc timeout' },
      { dedupeWindowMs: 60_000 },
    );
    assert.equal(a1.sent, true);
    assert.equal(a2.sent, false);
    assert.match(a2.error ?? '', /deduped/);
    assert.equal(calls, 1);

    // Same type/action/deployment but a DIFFERENT `message`: second call MUST
    // go through (distinct failure mode deserves a distinct alert).
    const b = await postAlert(
      'https://alerts.example.test/hook',
      { type: 'keeper-fault', action: 'poll', deployment: 'base', message: 'nonce gap detected' },
      { dedupeWindowMs: 60_000 },
    );
    assert.equal(b.sent, true);
    assert.equal(calls, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('keeper alert: malformed exponent dedupe env is ignored', async () => {
  const originalFetch = globalThis.fetch;
  const originalDedupeEnv = process.env.KEEPER_ALERT_DEDUP_WINDOW_SECS;
  let calls = 0;

  process.env.KEEPER_ALERT_DEDUP_WINDOW_SECS = '1e3';
  globalThis.fetch = (async () => {
    calls += 1;
    return new Response('{}', {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  }) as typeof fetch;

  try {
    const first = await postAlert('https://alerts.example.test/hook', { type: 'same-alert' });
    const second = await postAlert('https://alerts.example.test/hook', { type: 'same-alert' });

    assert.equal(first.sent, true);
    assert.equal(second.sent, true);
    assert.equal(calls, 2);
  } finally {
    globalThis.fetch = originalFetch;
    if (originalDedupeEnv == null) {
      delete process.env.KEEPER_ALERT_DEDUP_WINDOW_SECS;
    } else {
      process.env.KEEPER_ALERT_DEDUP_WINDOW_SECS = originalDedupeEnv;
    }
  }
});
