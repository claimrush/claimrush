# ClaimRush v1.0.0 spec quality standard

This file defines the wording rules and preferred structure for v1.0.0 specification documents under `docs/spec/`.

It is intentionally lightweight: the goal is to keep specs **coding-ready**, **reviewable**, and **indexer-safe**.

## Canonical references

- Canonical documentation entrypoint: `docs/v1.0.0-index.md`.
- Canonical conflict-resolution rules: `docs/v1.0.0-index.md`.

## Scope (what this standard enforces)

The `docs/spec/` folder contains a mix of document types:

- **Normative specs** (sources of truth)
  - Protocol-wide spec: `docs/spec/spec-v1.0.0.md`
  - Contract specs used by conflict resolution (see `docs/v1.0.0-index.md` → “Rule 2”)
  - ABI/config pins like `src/lib/Constants.sol`
- **Non-normative docs**
  - Implementer checklists (`*-implementer-checklist-*.md`)
  - Aids (glossary, state machines, test vectors, addenda)
  - Operational procedures referenced from security/ops docs

Enforcement model:

- §1 is enforced across all documents in `docs/spec/` and exists to remove reviewer ambiguity.
- §2 and §6–§8 are enforced for the normative specs listed above.
- §3–§5 and §9 are a template. Use them when authoring a new contract spec or doing a major rewrite, but existing v1.0.0 specs are not required to be retrofitted.

## When you MUST update specs

Update the relevant normative spec docs whenever a change affects:

- tokenomics (rates, splits, caps, schedules)
- role permissions or security policy
- pause surfaces / emergency behavior
- event schema (names, fields, semantics)
- user-facing UX guarantees (what a call does, revert reasons, expected outputs)

If anything conflicts, `docs/v1.0.0-index.md` rules determine which doc wins.

## 1) Binding vs guidance language (enforced)

To eliminate “is this required?” ambiguity, v1.0.0 uses a two-tier interpretation.

Binding requirements:

- Only the uppercase keywords below create a binding requirement:
  - MUST, MUST NOT
  - REQUIRED
  - NOT PART OF V1.0.0

Guidance (non-binding):

- Any statement using words like `recommended`, `should`, `may`, `optional`, `could`, `might`, etc. is guidance.
- Guidance can help implementers, but it does not override binding requirements.

Reviewer rule:

- Treat guidance as non-blocking.
- If correctness, security, or indexer behavior depends on a statement, express it as a binding requirement instead of guidance.

## 2) Wording rules for binding requirements (enforced)

- A binding requirement statement MUST use only: MUST, MUST NOT, REQUIRED, NOT PART OF V1.0.0.
- A binding requirement statement MUST NOT use softeners or ambiguity.
  - Examples of banned softeners include: SHOULD, MAY, CAN, COULD, MIGHT.
- Every implementation requirement MUST be expressed as a single outcome:
  - REQUIRED and in scope, or
  - NOT PART OF V1.0.0 and absent from the release.
- OS-dependent instructions MUST be expressed in a deterministic branch:
  - If your OS requires different steps: <steps>.
  - Default: <steps>.
- A binding requirement statement MUST NOT contain multiple acceptable paths for the same task.

## 3) Strict-format spec template (opt-in)

When authoring a new contract spec (or doing a major rewrite), use the strict-format structure below.

This template is optional for the existing v1.0.0 spec set.

## 4) Strict-format required section headings

Every strict-format spec document MUST contain the sections below in this order.

1) `## Overview`
2) `## Scope`
3) `## Terminology`
4) `## Dependencies and canonical links`
5) `## External interfaces`
6) `## Events`
7) `## State`
8) `## Permissions`
9) `## Invariants`
10) `## Errors and revert conditions`
11) `## Execution flows`
12) `## Edge cases`
13) `## Test vectors`

## 5) Strict-format required content by section

### Overview

- MUST name the component(s) covered (contract names, offchain service name, UI module name).
- MUST reference the supported networks (Base mainnet, chain ID 8453).

### Scope

- MUST contain an IN SCOPE list.
- MUST contain a NOT PART OF V1.0.0 list.
- MUST align with the current v1.0.0 release boundaries.

### Terminology

- MUST define any term that is not a Solidity or EVM baseline term.

### Dependencies and canonical links

- MUST link to the canonical sources of truth used by the spec:
  - Constants: `src/lib/Constants.sol`
  - Rounding: [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)
  - Permissions: `docs/manuals/developer/security-guardian-pausing.md` and the relevant contract spec
  - Invariants: the relevant contract spec and `docs/spec/state-machines-v1.0.0.md`
  - Events: `docs/analytics/dune-integration-pack-v1.0.0.md`
  - Subgraph schema: `docs/analytics/subgraph-schema-v1.0.0.md`

### External interfaces

- MUST enumerate every public/external function.
- Each function entry MUST include:
  - full signature (types included)
  - required caller permission
  - value transfer rules for every function that transfers ETH/WETH
  - state updates
  - emitted events
  - revert conditions

### Events

- MUST list each event name and signature.
- MUST match the canonical event schema in `docs/analytics/dune-integration-pack-v1.0.0.md`.

### State

- MUST list state variables and their meaning.
- MUST define units (wad/ray/bps/token decimals) for every numeric quantity.

### Permissions

- MUST define the owner/role surfaces and pause surfaces.
- MUST match `docs/manuals/developer/security-guardian-pausing.md` and the relevant contract spec.

### Invariants

- MUST list properties that always hold.
- MUST match the invariant sections in the relevant contract spec and `docs/spec/state-machines-v1.0.0.md`.

### Errors and revert conditions

- MUST list every revert condition per function.
- MUST define custom error names and their trigger conditions.

### Execution flows

- MUST define the sequence of calls and state transitions for each user-visible flow.

### Edge cases

- MUST enumerate boundary conditions, including:
  - zero amounts
  - max values
  - precision loss
  - reentrancy-sensitive external calls

### Test vectors

- MUST provide deterministic examples with inputs and expected outputs.
- MUST include at least one vector per major branch in Execution flows.

## 6) Banned phrases in binding requirements (enforced)

The phrases below MUST NOT appear in binding requirement statements.

They are allowed in guidance sections, headings, and explanatory text.

- BANNED: `optional`.
  - Replace with: `REQUIRED` or `NOT PART OF V1.0.0`.
- BANNED: `recommended`.
  - Replace with: `REQUIRED`.
- BANNED: `may`.
  - Replace with: `MUST` or `MUST NOT`.
- BANNED: `should`.
  - Replace with: `MUST` or `MUST NOT`.
- BANNED: `might`.
  - Replace with: `MUST` or `MUST NOT`.
- BANNED: `could`.
  - Replace with: `MUST` or `MUST NOT`.
- BANNED: `if you prefer`.
  - Replace with: `Choose A or B; publish only the selected outcome.`
- BANNED: `one of`.
  - Replace with: `Choose A or B; publish only the selected outcome.`
- BANNED: `either`.
  - Replace with: `Choose A or B; publish only the selected outcome.`
- BANNED: `TBD`, `TODO`, `WIP` → Replace with: a binding requirement or remove the unresolved placeholder.
- BANNED: `Note:` → Replace with: `Constraint:` or move the content into the relevant required section.

## 7) Single source of truth rules (enforced)

- Constants, addresses, and chain IDs MUST be sourced from `src/lib/Constants.sol`.
- Rounding and precision MUST follow the [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md).
- Permissions MUST follow `docs/manuals/developer/security-guardian-pausing.md` and the relevant contract spec.
- Invariants MUST follow the relevant contract spec and `docs/spec/state-machines-v1.0.0.md`.
- Event names/signatures and enum/codebooks MUST follow `docs/analytics/dune-integration-pack-v1.0.0.md`.
- Subgraph entities and field names MUST follow `docs/analytics/subgraph-schema-v1.0.0.md`.
- Conflicts between docs MUST be resolved using `docs/v1.0.0-index.md` → “Source of truth rules”.

## 8) No unresolved choices rule (enforced)

- Spec documents MUST NOT contain unknowns or unresolved choices.
- Published spec text MUST record one allowed outcome for each behavior it defines.

## 9) Required structure for function specs (template)

For any onchain function spec, include at minimum:

- **Purpose**: 1–2 sentences.
- **Signature**: exact function signature and visibility.
- **Inputs**: param meanings and units.
- **Preconditions**: requirements that MUST hold; list revert reasons where practical.
- **State changes**: storage writes and accounting changes.
- **External calls**: any calls to other contracts and assumptions.
- **Events**: what MUST be emitted and when.
- **Edge cases**: rounding, zero values, pause behavior.
- **Invariants touched**: link to the invariants document where applicable.
- **Examples**: a short numeric example that matches `src/lib/Constants.sol`.

## 10) Ambiguous specs are invalid

Ambiguous spec text is invalid. This includes:

- conflicting constants across docs
- missing event semantics for indexers
- `TODO` / `TBD` placeholders in the canonical v1.0.0 set
- function behavior described only informally without preconditions/state changes

If a behavior is intentionally unimplemented, document it as **NOT IMPLEMENTED** and keep it in the completeness table until shipped.

## 11) Spec acceptance checklist

A spec document is acceptable only when all items below are satisfied.

- [ ] Binding requirements use only MUST / MUST NOT / REQUIRED / NOT PART OF V1.0.0.
- [ ] Guidance is treated as non-binding and does not conflict with binding requirements.
- [ ] No unresolved choice exists; the document contains only published behavior.
- [ ] Constants/rounding/permissions/events are linked per §5 and follow the canonical sources in §7.
- [ ] (Strict-format only) Section headings match §4 exactly and appear in the same order.
- [ ] (Strict-format only) No banned phrase from §6 appears in binding requirement statements.
