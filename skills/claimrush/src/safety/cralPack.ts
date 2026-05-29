/**
 * CRAL pack loader.
 *
 * Reads `docs/manuals/developer/agents-and-automation.cral.yaml` (or an
 * override path) and surfaces the parts that matter for runtime decisions:
 *
 * - the canonical mental models (Crown loop, Furnace loop, connection)
 * - the operational guidance rules (self-run + delegated)
 * - the global conventions (integer-only units, dry-run defaults, deadlines)
 * - common agent confusions (so we can echo them in dry-run output)
 *
 * The result is *injected as agent context* (printable JSON / system-prompt
 * lines) without any new control-flow: the CRAL guardrails themselves are
 * already enforced in `cral.ts` and `networks.ts`. This module is purely
 * about giving the LLM (or human reviewer) the canonical wording so the
 * skill behaves like a real game-aware agent rather than a blind wrapper.
 */

import fs from 'node:fs';
import path from 'node:path';

import YAML from 'yaml';

import { repoRoot } from '../util/identity.js';

export type CralRule = {
  id: string;
  intent: string;
  rules?: string[];
  guards?: Record<string, unknown>;
  appliesTo?: string;
};

export type CralLoop = {
  id: string;
  name: string;
  mentalModel: string[];
  steps: { step: string; detail: string[] }[];
  safeNotes?: string[];
  commonConfusions?: string[];
};

export type CralPack = {
  packId: string;
  packVersion: string;
  conventions: {
    units: string[];
    execution: string[];
    logging: string[];
  };
  loops: CralLoop[];
  guidance: CralRule[];
  /** Shortlist of cross-cutting hard rules built from `guidance` + conventions. */
  hardRules: string[];
  /** Common agent confusions from each loop, deduped. */
  commonConfusions: string[];
};

let CACHE: { path: string; pack: CralPack } | null = null;

export function defaultCralPath(): string {
  const root = repoRoot();
  return path.join(root, 'docs', 'manuals', 'developer', 'agents-and-automation.cral.yaml');
}

export function resolveCralPath(override?: string): string {
  if (override && override.trim().length > 0) return path.resolve(override);
  const env = process.env.CR_SKILL_CRAL_PATH;
  if (env && env.trim().length > 0) return path.resolve(env.trim());
  return defaultCralPath();
}

/** Load + parse + extract the CRAL pack. Cached per resolved path. */
export function loadCralPack(override?: string): CralPack {
  const p = resolveCralPath(override);
  if (CACHE && CACHE.path === p) return CACHE.pack;

  if (!fs.existsSync(p)) {
    throw new Error(
      `[claimrush-skill] CRAL pack not found at ${p}. Set CR_SKILL_CRAL_PATH or pass --cral-path.`,
    );
  }

  const raw = fs.readFileSync(p, 'utf8');
  const doc = YAML.parse(raw) as Record<string, unknown>;
  const pack = extract(doc);
  CACHE = { path: p, pack };
  return pack;
}

function extract(doc: Record<string, unknown>): CralPack {
  const packId = String(doc.pack_id ?? 'agents-and-automation');
  const packVersion = String(doc.pack_version ?? 'unknown');

  const lang = (doc.language as Record<string, any>) ?? {};
  const conv = (lang.conventions as Record<string, any>) ?? {};
  const conventions = {
    units: asStringArray(conv.units),
    execution: asStringArray(conv.execution),
    logging: asStringArray(conv.logging),
  };

  const manifests = Array.isArray(doc.manifests) ? (doc.manifests as Record<string, any>[]) : [];

  const loops: CralLoop[] = manifests
    .filter((m) => typeof m.intent === 'string' && m.intent.startsWith('doc.game_loop'))
    .map((m) => extractLoop(m));

  const guidance: CralRule[] = manifests
    .filter((m) => m.intent === 'ops.guidance')
    .map((m) => ({
      id: String(m.id ?? 'unknown'),
      intent: String(m.intent ?? 'ops.guidance'),
      appliesTo: m.params?.applies_to ? String(m.params.applies_to) : undefined,
      rules: asStringArray(m.params?.rules),
      guards: (m.guards as Record<string, unknown>) ?? undefined,
    }));

  const commonConfusions = dedupe(loops.flatMap((l) => l.commonConfusions ?? []));

  const hardRules = buildHardRules({ conventions, guidance });

  return {
    packId,
    packVersion,
    conventions,
    loops,
    guidance,
    hardRules,
    commonConfusions,
  };
}

function extractLoop(m: Record<string, any>): CralLoop {
  const params = (m.params as Record<string, any>) ?? {};
  const stepsRaw = Array.isArray(params.step_by_step) ? params.step_by_step : [];
  const steps = stepsRaw
    .map((s: Record<string, any>) => ({
      step: String(s.step ?? ''),
      detail: asStringArray(s.detail),
    }))
    .filter((s: { step: string }) => s.step.length > 0);

  return {
    id: String(m.id ?? 'unknown'),
    name: String(params.loop_name ?? params.title ?? m.id ?? 'loop'),
    mentalModel: asStringArray(params.mental_model ?? params.tldr),
    steps,
    safeNotes: asStringArrayOrUndef(params.safe_execution_notes),
    commonConfusions: asStringArrayOrUndef(params.common_agent_confusions),
  };
}

function buildHardRules(input: {
  conventions: CralPack['conventions'];
  guidance: CralRule[];
}): string[] {
  const out: string[] = [];

  for (const u of input.conventions.units) out.push(`units: ${u}`);
  for (const x of input.conventions.execution) out.push(`execution: ${x}`);

  for (const g of input.guidance) {
    const tag = g.appliesTo ? `${g.appliesTo}` : g.id;
    for (const r of g.rules ?? []) out.push(`${tag}: ${r}`);
  }
  return dedupe(out);
}

function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x) => typeof x === 'string').map((x) => String(x));
}

function asStringArrayOrUndef(v: unknown): string[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const a = asStringArray(v);
  return a.length > 0 ? a : undefined;
}

function dedupe<T>(xs: T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const x of xs) {
    const k = JSON.stringify(x);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(x);
  }
  return out;
}

/**
 * Render the pack as a system-prompt-friendly string. Keep this short — it's
 * intended to be injected as agent context, not as a manual.
 */
export function renderSystemPrompt(pack: CralPack): string {
  const lines: string[] = [];
  lines.push(`You are operating ClaimRush via the @claimrush/openclaw-skill.`);
  lines.push(`CRAL pack: ${pack.packId} v${pack.packVersion}.`);
  lines.push('');
  lines.push('Hard rules (CRAL):');
  for (const r of pack.hardRules) lines.push(`- ${r}`);
  lines.push('');
  lines.push('Game loops:');
  for (const loop of pack.loops) {
    lines.push(`- ${loop.name} (${loop.id})`);
    for (const m of loop.mentalModel) lines.push(`    * ${m}`);
  }
  if (pack.commonConfusions.length > 0) {
    lines.push('');
    lines.push('Common agent confusions:');
    for (const c of pack.commonConfusions) lines.push(`- ${c}`);
  }
  return lines.join('\n');
}
