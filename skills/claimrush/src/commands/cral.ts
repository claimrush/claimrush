import { helpRequested, makeFlagBag } from '../util/args.js';
import { jsonStringify } from '../safety/cral.js';
import { loadCralPack, renderSystemPrompt, resolveCralPath } from '../safety/cralPack.js';

const HELP = `claimrush cral - load and surface CRAL safety pack as agent context

USAGE
  claimrush cral [--cral-path path] [--format json|prompt|hard-rules] [--pretty]

Outputs (default: json)
  - json:       the parsed CRAL pack (loops, guidance, common confusions, hard rules)
  - prompt:     a short system-prompt friendly string suitable for LLM injection
  - hard-rules: only the deduped hard-rules list (one per line)

NOTES
  - Defaults to docs/manuals/developer/agents-and-automation.cral.yaml; override
    with --cral-path or env CR_SKILL_CRAL_PATH.
  - The 'agent' verb automatically loads this pack and includes its hard-rules
    summary in the dry-run/execute output unless --no-cral-context is passed.
`;

export async function runCral(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }

  const cralPath = f.get('cral-path');
  const format = (f.get('format') ?? 'json').toLowerCase();
  const pretty = f.has('pretty');

  const pack = loadCralPack(cralPath);

  if (format === 'prompt') {
    console.log(renderSystemPrompt(pack));
    return 0;
  }
  if (format === 'hard-rules') {
    for (const r of pack.hardRules) console.log(r);
    return 0;
  }
  if (format === 'json') {
    console.log(
      jsonStringify(
        {
          packId: pack.packId,
          packVersion: pack.packVersion,
          source: resolveCralPath(cralPath),
          conventions: pack.conventions,
          hardRules: pack.hardRules,
          commonConfusions: pack.commonConfusions,
          loops: pack.loops.map((l) => ({
            id: l.id,
            name: l.name,
            mentalModel: l.mentalModel,
            stepCount: l.steps.length,
          })),
          guidance: pack.guidance.map((g) => ({
            id: g.id,
            appliesTo: g.appliesTo,
            rules: g.rules,
            guards: g.guards,
          })),
        },
        pretty,
      ),
    );
    return 0;
  }

  console.error(`[cral] unknown --format '${format}' (expected json|prompt|hard-rules)`);
  return 64;
}
