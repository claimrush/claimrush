import test from 'node:test';
import assert from 'node:assert/strict';
import dns from 'node:dns';

import { parseAndValidateOutboundUrlWithDns } from '../dist/src/security/url.js';

test('parseAndValidateOutboundUrlWithDns falls back to the default timeout on malformed timeout policy values', async (t) => {
  const originalLookup = dns.promises.lookup;
  dns.promises.lookup = () =>
    new Promise((resolve) => {
      setTimeout(() => resolve([{ address: '93.184.216.34', family: 4 }]), 50);
    });
  t.after(() => {
    dns.promises.lookup = originalLookup;
  });

  const url = await parseAndValidateOutboundUrlWithDns('https://example.com/path', 'SDK URL test', {
    dnsLookupTimeoutMs: 'bad-timeout',
    allowLoopback: false,
    allowPrivateIps: false,
    allowLinkLocal: false,
  });

  assert.equal(url.hostname, 'example.com');
});

test('parseAndValidateOutboundUrlWithDns still honors small valid timeout policies', async (t) => {
  const originalLookup = dns.promises.lookup;
  dns.promises.lookup = () =>
    new Promise((resolve) => {
      setTimeout(() => resolve([{ address: '93.184.216.34', family: 4 }]), 50);
    });
  t.after(() => {
    dns.promises.lookup = originalLookup;
  });

  await assert.rejects(
    () =>
      parseAndValidateOutboundUrlWithDns('https://example.com/path', 'SDK URL test', {
        dnsLookupTimeoutMs: 1,
        allowLoopback: false,
        allowPrivateIps: false,
        allowLinkLocal: false,
      }),
    /timed out after 1ms/,
  );
});

// Regression: when the DNS timeout wins the race against a still-pending
// `dns.promises.lookup`, and the underlying lookup later rejects, we MUST NOT
// leak an unhandledRejection. dnsLookupAll attaches a no-op .catch to the
// lookup promise before racing to guarantee this. If that fix regresses the
// Node process will emit `unhandledRejection` — this test fails on the first
// such event rather than the underlying assertion.
test('dnsLookupAll does not leak unhandledRejection when timeout beats a later-rejecting lookup', async (t) => {
  const originalLookup = dns.promises.lookup;
  // Lookup rejects well AFTER the timeout fires. The rejection reason is
  // distinctive so we can assert it is silently handled.
  const LATE_REJECT_MARKER = 'late-reject-should-be-swallowed';
  dns.promises.lookup = () =>
    new Promise((_resolve, reject) => {
      setTimeout(() => reject(new Error(LATE_REJECT_MARKER)), 60);
    });

  // Capture unhandled rejections during this test body. We install a local
  // listener that remembers every event and fail if any of them matches the
  // marker. Other parallel tests could trip this handler with unrelated
  // errors, so we filter to the marker only.
  const seen = [];
  const listener = (reason) => {
    const msg = String((reason && reason.message) || reason || '');
    if (msg.includes(LATE_REJECT_MARKER)) seen.push(msg);
  };
  process.on('unhandledRejection', listener);
  t.after(() => {
    process.off('unhandledRejection', listener);
    dns.promises.lookup = originalLookup;
  });

  await assert.rejects(
    () =>
      parseAndValidateOutboundUrlWithDns('https://example.com/path', 'SDK URL test', {
        dnsLookupTimeoutMs: 10,
        allowLoopback: false,
        allowPrivateIps: false,
        allowLinkLocal: false,
      }),
    /timed out after 10ms/,
  );

  // Give the late rejection a chance to fire and the event loop a turn to
  // surface any unhandledRejection. 120ms > 60ms late-reject + generous slack.
  await new Promise((resolve) => setTimeout(resolve, 120));

  assert.equal(
    seen.length,
    0,
    `dnsLookupAll leaked an unhandledRejection from a late-rejecting dns.promises.lookup: ${seen.join(', ')}`,
  );
});
