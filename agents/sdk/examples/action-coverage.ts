import 'dotenv/config';

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { stringifyJson } from '../src/index.js';

type CliOpts = {
  schemaPath: string;
  pretty: boolean;
};

function defaultSchemaPath(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return resolve(here, '../../schemas/agent-plan.v1.schema.json');
}

function parseArgs(argv: string[], env: NodeJS.ProcessEnv): CliOpts {
  const get = (key: string): string | undefined => {
    const pref = `--${key}=`;
    const hit = argv.find((a) => a.startsWith(pref));
    if (hit) return hit.slice(pref.length);
    const idx = argv.findIndex((a) => a === `--${key}`);
    if (idx >= 0) return argv[idx + 1];
    return undefined;
  };

  const has = (flag: string): boolean => argv.includes(`--${flag}`);

  const help = has('help') || argv.includes('-h');
  if (help) {
    console.log(`
ClaimRush AgentPlan action coverage

Reads agents/sdk/schemas/agent-plan.v1.schema.json and outputs the supported action kinds.
This is useful to:
- confirm your agent runtime supports the actions you think it does
- diff supported actions across branches/releases

Usage
  npm -C agents/sdk run example:action-coverage -- [options]

Options
  --schema-path <path>     Path to agent-plan schema JSON
                           (default: schemas/agent-plan.v1.schema.json)
  --pretty                Pretty-print JSON

Env vars
  AGENT_PLAN_SCHEMA        Same as --schema-path
  PRETTY=1                 Same as --pretty
`);
    process.exit(0);
  }

  const schemaPath =
    (get('schema-path') ?? env.AGENT_PLAN_SCHEMA ?? '').trim() || defaultSchemaPath();
  const pretty = has('pretty') || env.PRETTY === '1';

  return { schemaPath, pretty };
}

type Coverage = {
  schemaPath: string;
  total: number;
  kinds: string[];
  groups: Record<string, string[]>;
  generatedAt: string;
};

function loadKindsFromSchema(schemaPath: string): string[] {
  const raw = readFileSync(schemaPath, 'utf8');
  const schema = JSON.parse(raw) as any;

  const oneOf = schema?.properties?.actions?.items?.oneOf;
  if (!Array.isArray(oneOf)) {
    throw new Error(
      `Schema at ${schemaPath} does not look like AgentPlan.v1 (missing properties.actions.items.oneOf[])`,
    );
  }

  const kinds: string[] = [];
  for (const item of oneOf) {
    const k = item?.properties?.kind?.const;
    if (typeof k === 'string' && k.trim()) kinds.push(k.trim());
  }

  const uniq = Array.from(new Set(kinds));
  uniq.sort();
  return uniq;
}

function groupKinds(kinds: string[]): Record<string, string[]> {
  const groups: Record<string, string[]> = {};
  for (const k of kinds) {
    const group = k.includes('.') ? k.split('.')[0] : 'other';
    if (!groups[group]) groups[group] = [];
    groups[group].push(k);
  }
  for (const g of Object.keys(groups)) {
    groups[g].sort();
  }
  return groups;
}

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2), process.env);
  const kinds = loadKindsFromSchema(opts.schemaPath);
  const groups = groupKinds(kinds);

  const out: Coverage = {
    schemaPath: opts.schemaPath,
    total: kinds.length,
    kinds,
    groups,
    generatedAt: new Date().toISOString(),
  };

  console.log(stringifyJson(out, { pretty: opts.pretty }));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
