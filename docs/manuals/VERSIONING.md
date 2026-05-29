# Versioning Policy for Manuals

This policy governs how and where protocol version numbers (e.g. `v1.0.0`) appear in
`docs/manuals/**`. The goal is to keep the manuals truthful as the repo evolves,
without forcing a rewrite every release.

## Rule of thumb

Before writing `v1.0.0` in a doc, ask: **if I removed the version, would the sentence
become more wrong?**

- Yes → keep it. It's scoping a time-bounded claim.
- No → remove it. It's decoration that will silently go stale.

## The three categories

### 1. Page and section titles — never versioned

Do not put a version in an H1 or page subtitle. The docs site reflects the current
`main` branch; a hardcoded version in the title will drift silently the day after
the next tag.

```markdown
# ClaimRush Docs                <!-- good -->
# ClaimRush Docs (v1.0.0)       <!-- bad -->
```

Section-level headers (`## Key params (v1.0.0)`) are acceptable *only* when the
section documents version-scoped data (constants, ABI notes, protocol rules). Treat
these as Category 3 (semantic claims), not titles.

This rule is enforced in CI by `scripts/check_manuals_truthiness.py`.

### 2. Cross-links to versioned filenames — keep exactly

Links pointing to frozen snapshot files (`docs/spec/spec-v1.0.0.md`,
`docs/analytics/dune-integration-pack-v1.0.0.md`, etc.) are filesystem paths, not
statements about *this* doc's version. Leave them exactly as-is.

When a new snapshot is published:

- Create the new file (`*-v1.1.0.md`) alongside the old one.
- Update cross-links deliberately; do not bulk-rename.
- Do not delete the old snapshot — it's the historical record.

### 3. Semantic / scoped claims — keep the version tag

When describing protocol behavior, constants, or design decisions that are true as
of a specific version, include the version. This is load-bearing: it scopes the
claim in time and forces an explicit review on the next release.

Good examples:

- "Listing, selling, and escrow management are intentionally not delegated in v1.0.0."
- "v1.0.0: `HARVEST_MAX_SLIPPAGE_BPS = 100` (1%)"
- "In v1.0.0, the primary materialization point is takeover finalization."
- "Reserved event names (not declared in v1.0.0): …"

For constants specifically, prefer citing the canonical source
(`src/lib/Constants.sol`) in addition to the version tag.

## Release checklist

When cutting a new protocol version (e.g. v1.1.0):

1. `rg 'v1\.0\.0' docs/manuals/` — review every hit.
2. For each occurrence, decide one of:
   - **Update** to the new version if the behavior still applies unchanged.
   - **Leave** at `v1.0.0` if it documents legacy behavior that still needs to be
     discoverable (common for removed features and historical constants).
   - **Split** into before/after if the behavior changed between versions.
3. For new frozen snapshots, copy the relevant `docs/spec/*-v1.0.0.md` to
   `*-v1.1.0.md` and update manuals' cross-links selectively.
4. Re-run `python3 scripts/check_manuals_truthiness.py` to catch H1 regressions.

## Why not dynamic substitution?

We intentionally do not template versions into markdown (e.g. `{{ VERSION }}`).
The three categories above require different behavior — only Category 3 would
benefit from substitution, and substituting *those* would be actively harmful
(it would rewrite historical claims each release). Inline, explicit version
tags keep staleness visible instead of hiding it behind a template.
