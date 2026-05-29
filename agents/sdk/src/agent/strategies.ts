import type { Address } from 'viem';

import type { ClaimRushSnapshot } from '../snapshot.js';

import { safeErrorString } from '../security/redact.js';
import { parseStrictNonNegativeSafeInteger } from '../integers.js';

import {
  buildActionPlan,
  type PolicyCallerContext,
  type PolicyConfig,
  type PolicyDelegationContext,
  type PolicyState,
} from './policy.js';
import type { AgentAction } from './types.js';

export type AgentStrategyContext = {
  chain: string;
  chainId: number;
  agent: Address;
  user: Address;

  snapshot: ClaimRushSnapshot;
  config: PolicyConfig;
  state: PolicyState;
  nowMs: number;

  caller?: PolicyCallerContext;
  delegation?: PolicyDelegationContext;
};

export type AgentStrategyResult = {
  actions: AgentAction[];
  /** If true, stop running subsequent strategies after this one. */
  stop?: boolean;
  /**
   * Optional debug notes included in traces.
   *
   * Safety: these will be sanitized (URL + hostname token redaction) and size-limited
   * before being written to artifacts / monitor endpoints.
   */
  notes?: string[];
};

export type AgentStrategy = {
  /** Stable identifier for logs/telemetry. */
  id: string;
  /** Higher runs earlier. Default: 0. */
  priority?: number;

  /**
   * Return either:
   * - AgentAction[]
   * - AgentStrategyResult
   * - undefined / void (equivalent to no-op)
   */
  propose:
    | ((
        ctx: AgentStrategyContext,
      ) => Promise<AgentStrategyResult | AgentAction[] | undefined | void>)
    | ((ctx: AgentStrategyContext) => AgentStrategyResult | AgentAction[] | undefined | void);

  /** Convenience: if true, stop after this strategy when it proposes any actions. */
  stopOnActions?: boolean;
};

export type AgentStrategyTrace = {
  id: string;
  priority: number;
  startedAtMs: number;
  durationMs: number;
  ok: boolean;
  actionCount: number;
  stop?: boolean;
  error?: string;
  notes?: string[];
};

// Prevent debug notes from leaking secrets (URLs with embedded keys, token-like host labels)
// and from blowing up artifact sizes.
const MAX_TRACE_NOTES = 20;
const MAX_NOTE_CHARS = 500;

function sanitizeNotes(v: unknown): string[] | undefined {
  if (!Array.isArray(v) || v.length === 0) return undefined;

  const out: string[] = [];
  for (const item of v) {
    if (out.length >= MAX_TRACE_NOTES) break;

    const raw = typeof item === 'string' ? item : String(item);
    let s = safeErrorString(raw).trim();
    if (!s) continue;

    if (s.length > MAX_NOTE_CHARS) {
      s = s.slice(0, MAX_NOTE_CHARS) + '...';
    }

    out.push(s);
  }

  return out.length ? out : undefined;
}

function normalizeResult(
  v: AgentStrategyResult | AgentAction[] | undefined | void,
): AgentStrategyResult {
  if (!v) return { actions: [] };
  if (Array.isArray(v)) return { actions: v };
  return {
    actions: Array.isArray(v.actions) ? v.actions : [],
    stop: v.stop,
    notes: v.notes,
  };
}

export async function runStrategies(params: {
  strategies: AgentStrategy[];
  ctx: AgentStrategyContext;
  /** Optional cap on the total number of actions collected across all strategies. */
  maxActions?: number;
}): Promise<{ actions: AgentAction[]; traces: AgentStrategyTrace[] }> {
  const input = params.strategies ?? [];
  const strategies = [...input];

  const maxActionsRaw = params.maxActions;
  const maxActions =
    maxActionsRaw === undefined || maxActionsRaw === null
      ? undefined
      : parseStrictNonNegativeSafeInteger(maxActionsRaw);

  strategies.sort((a, b) => {
    const ap = a.priority ?? 0;
    const bp = b.priority ?? 0;
    if (ap !== bp) return bp - ap; // higher first
    return String(a.id).localeCompare(String(b.id));
  });

  const actions: AgentAction[] = [];
  const traces: AgentStrategyTrace[] = [];

  for (const s of strategies) {
    if (maxActions !== undefined && actions.length >= maxActions) break;

    const startedAtMs = Date.now();
    const priority = s.priority ?? 0;

    try {
      const out = normalizeResult(await s.propose(params.ctx));

      // Collect actions with an optional global cap to prevent unbounded memory/disk growth
      // from buggy or malicious strategies.
      const remaining = maxActions !== undefined ? maxActions - actions.length : undefined;
      let added = 0;

      if (remaining !== undefined) {
        for (const a of out.actions) {
          if (added >= remaining) break;
          actions.push(a);
          added++;
        }
      } else {
        for (const a of out.actions) {
          actions.push(a);
          added++;
        }
      }

      const dropped = out.actions.length - added;
      const truncated = dropped > 0;
      const reachedCap = maxActions !== undefined && actions.length >= maxActions;

      const stop = Boolean(out.stop || (s.stopOnActions && added > 0) || reachedCap);

      const extraNotes: string[] = [];
      if (truncated) {
        extraNotes.push(
          `note: truncated actions to maxActions=${String(maxActions)} (added=${added} dropped=${dropped})`,
        );
      } else if (reachedCap && !out.stop && !(s.stopOnActions && added > 0)) {
        extraNotes.push(`note: reached maxActions cap=${String(maxActions)}; stopping strategies`);
      }

      // Avoid copying arbitrarily large note arrays. Keep only a small prefix plus our extra notes.
      const noteItems: unknown[] = [];
      const maxBaseNotes = Math.max(0, MAX_TRACE_NOTES - extraNotes.length);

      if (Array.isArray(out.notes)) {
        for (const n of out.notes) {
          if (noteItems.length >= maxBaseNotes) break;
          noteItems.push(n);
        }
      } else if (out.notes && maxBaseNotes > 0) {
        noteItems.push(out.notes);
      }

      for (const n of extraNotes) noteItems.push(n);

      traces.push({
        id: s.id,
        priority,
        startedAtMs,
        durationMs: Date.now() - startedAtMs,
        ok: true,
        actionCount: added,
        stop,
        notes: sanitizeNotes(noteItems),
      });

      if (stop) break;
    } catch (err) {
      traces.push({
        id: s.id,
        priority,
        startedAtMs,
        durationMs: Date.now() - startedAtMs,
        ok: false,
        actionCount: 0,
        error: safeErrorString(err),
      });
    }
  }

  return { actions, traces };
}

/**
 * Wrapper strategy around the built-in policy `buildActionPlan(...)`.
 *
 * Tip: include this strategy as a low-priority fallback after your custom strategies.
 */
export function createPolicyStrategy(params?: {
  id?: string;
  priority?: number;
  stopOnActions?: boolean;
}): AgentStrategy {
  const id = params?.id ?? 'policy.default';
  const priority = params?.priority ?? 0;
  const stopOnActions = params?.stopOnActions ?? false;

  return {
    id,
    priority,
    stopOnActions,
    propose: (ctx: AgentStrategyContext): AgentStrategyResult => {
      const a = buildActionPlan({
        snapshot: ctx.snapshot,
        config: ctx.config,
        state: ctx.state,
        nowMs: ctx.nowMs,
        caller: ctx.caller,
        delegation: ctx.delegation,
      });
      return { actions: a };
    },
  };
}
