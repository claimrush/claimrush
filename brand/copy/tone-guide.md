# Tone guide

ClaimRush should feel **severe, authored, crypto-native, and consequential**.
Remove friendly SaaS language. Remove cheerful onboarding language. Remove generic startup phrasing.
Keep everything clear, scannable, and accessible.


## Copy buckets

Every visible string belongs to one of four surfaces. Each surface has its own register.

### Gameplay UI
Crown, Furnace, Locks, LP Vault, Market, Overview actions, toasts, share objects.

Register: **ceremonial, severe, declarative**.

Copy should read like protocol state, not product encouragement. Announce facts. Do not congratulate, coach, or reassure.

### Navigation
Navbar, footer, page titles, breadcrumbs, tab labels.

Register: **compact, hard, scannable**.

Labels must orient a first-time crypto user instantly. Prefer the shortest unambiguous word. Wayfinding clarity beats tonal purity.

### Operator / Security
Admin panels, security pages, delegation settings, risk gates.

Register: **clinical, technical, procedural**.

Write like a runbook. State conditions, actions, and consequences. No warmth, no softening.

### Docs / Manuals
Docs, manuals, walkthroughs, and tooltips explaining mechanics.

Register: **formal, exact, clear**.

Explain once, precisely. Do not simplify to the point of omission. Do not add encouragement.


## Anti-patterns

These phrases are banned. Replacements are suggested defaults — final choice must be judged per-surface.

| Banned phrase | Suggested replacement | Notes |
|---|---|---|
| Dashboard (as page name) | Overview | Route: `/overview`. Canonical label: "Overview". |
| How it works | Game mechanics, Vault mechanics | Use the specific noun |
| Learn more | Details, References | |
| Your next move | Actions | |
| Explore / Discover | Open, Browse | |
| You're all set | Confirmed onchain. | |
| Something went wrong | Operation failed. | |
| Congratulations! | Achievement unlocked | |
| Thank you | (remove or replace with factual acknowledgement) | |
| Great job / All good / You're caught up | (state the actual status) | |
| Get in touch | Contact | |
| Easy / Simple | (remove — do not describe difficulty) | |
| Welcome back | (remove) | |


## Word policy

Extends `voice.md`. These rules apply everywhere.

### Required verb substitutions

"Claim" must never appear as a verb in UI. This is both a tone rule and a conceptual rule — "Claim" is a mining claim (lore) and the token ticker (CLAIM), not a DeFi rewards verb.

| Context | Correct verb |
|---|---|
| ETH royalty payouts | **Collect** |
| LP rewards (CLAIM) | **Harvest** |
| Withdrawing deposited funds | **Withdraw** |

### Banned words (additive to `voice.md`)

easy, simple, welcome, thank you, great job, you're all set, something went wrong, learn more, explore, discover, your next move, dashboard (as a page name — route is `/overview`), starter pack, quick start

### Sentence style

- Short sentences. Active voice.
- Declarative, not interrogative. ("Pending actions." not "What should I do?")
- No exclamation marks in operational or security copy.
- Exclamation marks acceptable only in gameplay moments (takeover success, reign events).


## Canonical naming

These labels are final and should be used consistently across all surfaces:

| Label | Usage | Notes |
|---|---|---|
| **Getting Started** | Nav / menu / onboarding section label | Wayfinding clarity per principle #1 |
| **Tutorials** | Menu / category / library label | Wayfinding clarity per principle #1 |
| **Walkthrough** | The single guided product flow (singular) | Footer CTA; modal title for the guided walkthrough |
| **Overview** | The main wallet/account page | Route: `/overview` |


## Application principles

1. **Nav labels prioritize wayfinding over ideology.** If a replacement is more opaque than the original, the original wins until a clearer option surfaces.
2. **Contact / support surfaces stay neutral.** Clean, brief, functional. Not mythic, not cold.
3. **Replacement choices are suggestions, not mandates.** Pressure-test each against instant readability on its actual page before committing.
4. **Do not rename protocol concepts** (Crown, Furnace, Baron, King, etc.) unless clearly improved.
5. **Preserve accessibility.** Aria labels, alt text, and screen-reader copy should be descriptive and plain.


## Reviewer checklist

When reviewing public docs, visible strings, or brand copy:

1. Which copy bucket does this string belong to?
2. Does the register match?
3. Does it use any banned phrase?
4. Does it use "Claim" as a verb?
5. Is it scannable on mobile?
6. Would a first-time crypto user understand it without context?
