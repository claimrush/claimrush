# Linking Convention for Manuals

This policy governs how Markdown links inside `docs/manuals/**` reach their
targets. The goal is for every link to render correctly **on the deployed
docs sites** (`developers.claimru.sh`, `docs.claimru.sh`) and on **GitHub**,
without silently 404-ing when the manuals are mirrored into the Nextra
content trees.

## Why a convention is needed

The developer manual lives in `docs/manuals/developer/` in this repository.
The user manual is published at `https://docs.claimru.sh/` and is generated
from a separate source tree that is not mirrored here. Two downstreams
consume the manuals:

1. **Deployed Nextra sites** at `https://developers.claimru.sh/` (developer)
   and `https://docs.claimru.sh/` (user), each generated from its source
   subtree and serving only that subtree.
2. **GitHub web view** of `docs/manuals/**` directly.

The deployed sites only serve files inside their generated content tree.
A relative link that climbs out of the manual (e.g. `../../../README.md`)
resolves on GitHub but 404s on the deployed site.

## Rule of thumb

Before writing a relative link, ask: **does the target live inside the
same manual tree?**

- Yes → relative link is correct.
- No → use an absolute URL (deployed site, GitHub permalink, or asset URL).

## The four rules

### 1. In-tree (same manual) — relative path

If the target is another `.md` in the same manual tree (the developer
manual under `docs/manuals/developer/`, or the user manual in its source
repository), use a normal relative link.

```markdown
[Getting Started](getting-started.md)
[Tutorials index](tutorials/README.md)
```

### 2. Cross-manual (developer ↔ user) — absolute deployed URL

If you need to link from one manual to a page in the other, use the deployed
custom-domain URL with the Nextra slug (no `.md` extension).

```markdown
[Agents and automation](https://developers.claimru.sh/agents-and-automation)
[Getting Started](https://docs.claimru.sh/getting-started)
```

Slug rules:

```
agents-and-automation.md          -> /agents-and-automation
tutorials/take-the-crown.md       -> /tutorials/take-the-crown
```

### 3. Out-of-tree source code or non-manual files — GitHub permalink

For any file outside the manual tree (`src/`, `script/`, `test/`,
`agents/sdk/`, root files like `LICENSE` or `README.md`, `docs/architecture/`,
etc.), use a GitHub blob/tree URL pinned to `main`.

```markdown
[`script/DeployLocal.s.sol`](https://github.com/claimrush/claimrush/blob/main/script/DeployLocal.s.sol)
[`skills/claimrush/`](https://github.com/claimrush/claimrush/tree/main/skills/claimrush)
[LICENSE](https://github.com/claimrush/claimrush/blob/main/LICENSE)
```

Use `/blob/main/<path>` for files and `/tree/main/<path>` for directories.

### 4. CRAL companion yaml — deployed asset URL

The CRAL manifest at `docs/manuals/developer/agents-and-automation.cral.yaml`
is mirrored to the developers-site `public/` folder and served from root.
Always link to the deployed copy so it works in both the rendered page and
inside the yaml metadata that downstream tooling reads.

```markdown
[CRAL manifest](https://developers.claimru.sh/agents-and-automation.cral.yaml)
```

## What about anchors

Preserve anchors at the end of the URL in all four rules:

```markdown
[keeper README — Adaptive cadence](https://github.com/claimrush/claimrush/blob/main/keeper/README.md#adaptive-cadence--websocket-event-bus-v110)
[Furnace section](furnace.md#takeover-flow)
```

## Pre-launch caveat

Until the public repo at `github.com/claimrush/claimrush` is live, links
written under Rule 3 will return 404. This is expected; they resolve the
moment the repo is uploaded. Authors should still write them in the
canonical form so no follow-up edit is needed at launch.

## Enforcement

A CI check in [`scripts/check_release_docs_consistency.py`](https://github.com/claimrush/claimrush/blob/main/scripts/check_release_docs_consistency.py)
fails the build if a manual `.md` contains a relative link whose resolved
target escapes the manual tree. The check is conservative: only relative
links are inspected. Absolute URLs (`https://`, `mailto:`, etc.) are
trusted.

## Note for contributors editing the developer manual

When you submit a Markdown change in this repo against
[`docs/manuals/developer/`](developer/), the deployed copy at
`https://developers.claimru.sh/` is updated by maintainers as part of
the publish pipeline. Land your change here as plain Markdown that
follows the four link rules above; the rendered page on the deployed
site will be republished from your edit in the next site refresh.
