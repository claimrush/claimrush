#!/usr/bin/env python3
"""Check public docs do not use the word "claim" as a verb.

Brand canon (see brand/copy/tone-guide.md and brand/copy/voice.md) requires:
- Collect  (for ETH payouts)
- Harvest  (for token rewards)
- Withdraw (for returning principal)

The rule is intentionally narrow:
- We scan only allowlisted doc prose under docs/manuals/{user,developer} and
  docs/spec. Other allowlisted paths describe onchain behaviour and frequently
  reference identifier-style names (function names, token constants, NatSpec
  anchors) where the word "claim" is correct as a noun or identifier.
- Code fences, inline backticks, Markdown links, URLs, and tokens that are
  part of CamelCase / snake_case / SCREAMING_SNAKE / dotted identifiers are
  stripped before matching.
- We flag only verb-shaped usages: "<pronoun|user|caller|holder|...> (can|may
  |must|will|should) claim", "to claim <object>", and "claim <noun>" where
  the following word looks like a plain-English object (rewards, payouts,
  etc.) rather than an identifier.

Exit status:
  0 - no verb-shaped uses found.
  1 - at least one suspicious line found; a report is printed to stderr.

This gate is intentionally conservative. If it flags a legitimate noun use,
tighten the sentence wording; do not add suppressions.
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

SCAN_ROOTS = [
    REPO_ROOT / "docs" / "manuals" / "user",
    REPO_ROOT / "docs" / "manuals" / "developer",
    REPO_ROOT / "docs" / "spec",
]

# Verb-shaped patterns. All match case-insensitively.
SUBJECTS = (
    r"users?|anyone|everyone|you|we|they|caller|callers|"
    r"holder|holders|owner|owners|bot|bots|operator|operators|"
    r"integrator|integrators|player|players|barons?|king|kings"
)
MODALS = r"can|may|must|will|should|could|to"

VERB_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "subject-modal-claim",
        re.compile(
            rf"\b(?:{SUBJECTS})\s+(?:{MODALS})\s+(?:also\s+|still\s+|directly\s+|further\s+|now\s+|then\s+)?claims?\b",
            re.IGNORECASE,
        ),
    ),
    (
        "to-claim-object",
        re.compile(
            r"\bto\s+claim\s+(?:accrued|the|their|your|our|pending|available|"
            r"rewards?|payouts?|eth|tokens?|barons?|royalt)\w*",
            re.IGNORECASE,
        ),
    ),
    (
        "claim-noun-object",
        re.compile(
            r"\bclaims?\s+(?:accrued\s+)?(?:rewards?|payouts?|tokens?|"
            r"royalt\w+|barons?\s+(?:rewards?|eth|payouts?))\b",
            re.IGNORECASE,
        ),
    ),
    (
        "claim-all-cta",
        re.compile(
            r"\"?\bclaim\s+all\b\"?",
            re.IGNORECASE,
        ),
    ),
    (
        "verb-gerund",
        re.compile(
            r"\bclaiming\s+(?:rewards?|payouts?|barons?|royalt\w+|eth|tokens?)\b",
            re.IGNORECASE,
        ),
    ),
    # Imperative CTA forms often used in headings and bullets:
    #   "Claim your rewards", "Claim the pending payouts", "Claim pending ETH",
    #   "Claim your pending ETH today".
    # Anchored to start-of-line (after optional Markdown heading / list markers
    # / bold / italic noise) to avoid matching mid-sentence noun phrases. We
    # allow up to three qualifier words (the|your|their|our|pending|available|
    # accrued|all) before the object so phrases like "Claim your pending ETH"
    # still match.
    (
        "imperative-claim-cta",
        re.compile(
            r"^\s*(?:#{1,6}\s+|[-*+]\s+|\d+\.\s+|\*\*\s*|\*\s*|_\s*)*"
            r"claim\s+"
            r"(?:(?:the|your|their|our|pending|available|accrued|all)\s+){0,3}"
            r"(?:rewards?|payouts?|tokens?|eth|barons?|royalt\w+)"
            r"\b",
            re.IGNORECASE,
        ),
    ),
]

CODE_FENCE = re.compile(r"^\s*(?:```|~~~)")
INLINE_BACKTICK = re.compile(r"`[^`]*`")
MARKDOWN_LINK_TARGET = re.compile(r"\]\([^)]+\)")
URL = re.compile(r"https?://\S+")
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
# Strip identifier-shaped tokens that contain "claim" (case-insensitive) AND
# an uppercase ASCII letter at a non-initial position. The non-initial
# constraint is important: a sentence-starting imperative verb like
# "Claim your rewards" capitalises the C, but its only uppercase is at
# position 0. If we stripped on any uppercase, the imperative verb would be
# deleted before the downstream pattern could flag it and the whole gate
# would be a silent no-op.
#
# What this DOES strip:
#   - CLAIM                (all caps, uppercase at position 1..4)
#   - veCLAIM              (uppercase at position 2+)
#   - ClaimAllHelper       (uppercase at position 5, 8)
#   - claimShareholderEth  (uppercase at position 5)
#   - SCREAMING_SNAKE_CLAIM
#
# What this does NOT strip (and must not):
#   - claim / claims / claiming / claimed (bare English verb forms)
#   - Claim (sentence-start; uppercase only at position 0)
#
# CRITICAL: the uppercase lookahead MUST be case-sensitive. If re.IGNORECASE
# applies to [A-Z], it matches a-z and effectively strips every word
# containing 'claim', silently disabling the entire gate. We force
# case-sensitive matching inside the uppercase lookahead via (?-i:...).
IDENTIFIER_TOKEN = re.compile(
    r"\b(?=\w*[Cc][Ll][Aa][Ii][Mm])(?=\w[A-Za-z0-9_]*(?-i:[A-Z]))\w+\b"
)
# Also strip dotted identifiers such as royalties.claimShareholderEth.
DOTTED_IDENTIFIER = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_.]*\b")
YAML_FRONTMATTER_FENCE = re.compile(r"^---\s*$")
# Strip noun-phrase usages of "CLAIM" where it is the token ticker rather than
# the verb. We already strip all-uppercase CLAIM via IDENTIFIER_TOKEN (it has
# no uppercase letter after the required lookaheads fail for bare lowercase,
# but CLAIM itself is all caps so matches both lookaheads).

# Hard allow: phrases where "claim" is unambiguously a noun and cannot be
# rewritten without harming correctness. Keep this list empty or very small.
# Each entry is a case-insensitive literal substring; if a stripped line
# contains one, it is not flagged.
NOUN_ALLOWLIST: tuple[str, ...] = (
    # The onchain "mining claim" concept is a noun in the protocol; it is
    # fine to describe it as such in prose.
    "mining claim",
    "mining claims",
    # "CLAIM" (all caps) is the token ticker and not the English word.
    # IDENTIFIER_TOKEN stripping handles this, but keep as a belt-and-braces
    # guard for edge cases.
)


def strip_noise(line: str) -> str:
    """Remove code-like tokens so only prose is left for matching."""
    out = INLINE_BACKTICK.sub(" ", line)
    out = MARKDOWN_LINK_TARGET.sub(" ", out)
    out = URL.sub(" ", out)
    out = DOTTED_IDENTIFIER.sub(" ", out)
    out = IDENTIFIER_TOKEN.sub(" ", out)
    return out


def strip_html_comments(text: str) -> str:
    """Remove <!-- ... --> blocks (possibly multi-line) before line splitting."""
    return HTML_COMMENT.sub(" ", text)


def iter_markdown_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in SCAN_ROOTS:
        if not root.exists():
            continue
        files.extend(sorted(root.rglob("*.md")))
    return files


def scan_text(text: str) -> list[tuple[int, str, str]]:
    """Scan a Markdown document body for verb-shaped uses of 'claim'."""
    hits: list[tuple[int, str, str]] = []
    # Drop HTML comments first so prose inside them doesn't get scanned.
    # We preserve line breaks so that error line numbers still match source.
    text = HTML_COMMENT.sub(
        lambda m: "\n" * m.group(0).count("\n"),
        text,
    )

    in_fence = False
    in_frontmatter = False
    lines = text.splitlines()
    # YAML frontmatter only counts if it appears at the very top of the file.
    if lines and YAML_FRONTMATTER_FENCE.match(lines[0]):
        in_frontmatter = True

    for lineno, raw in enumerate(lines, start=1):
        # Frontmatter: skip everything between the opening '---' and its match.
        if in_frontmatter:
            if lineno > 1 and YAML_FRONTMATTER_FENCE.match(raw):
                in_frontmatter = False
            continue
        # Fenced code: matches ``` or ~~~ with optional leading whitespace.
        if CODE_FENCE.match(raw):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stripped = strip_noise(raw)
        if any(token.lower() in stripped.lower() for token in NOUN_ALLOWLIST):
            continue
        for name, pattern in VERB_PATTERNS:
            if pattern.search(stripped):
                hits.append((lineno, name, raw.rstrip()))
                break
    return hits


def scan_file(path: pathlib.Path) -> list[tuple[int, str, str]]:
    return scan_text(path.read_text(encoding="utf-8"))


# Regression fixtures. SELF_TEST_* are kept close to the scanner so a linter
# bug that silently disables the gate (e.g. IDENTIFIER_TOKEN stripping the
# bare verb) is caught by `--self-test` in CI.
SELF_TEST_BAD = """\
# Sample

Users can claim rewards from the furnace.

- Claim your pending ETH today
- claim all payouts
- Anyone may claim pending barons rewards
- claiming rewards is easy
"""

SELF_TEST_GOOD = """\
# Sample

The CLAIM token and ClaimAllHelper contract both ship.

- Call `royalties.claimShareholderEth` to collect accrued ETH.
- The mining claim entity is documented in the subgraph schema.

```solidity
function claim(address token) external {}
```

~~~
pseudo code: users may claim here but this is inside a fence
~~~

<!-- Reviewer note: claim is a verb here but inside an HTML comment, so it is
allowed and this file should still pass. -->
"""


def run_self_test() -> int:
    bad_hits = scan_text(SELF_TEST_BAD)
    good_hits = scan_text(SELF_TEST_GOOD)

    errors: list[str] = []
    if len(bad_hits) < 5:
        errors.append(
            f"[claim-as-verb:self-test] expected >=5 verb hits in BAD fixture, got {len(bad_hits)}: {bad_hits}"
        )
    if good_hits:
        errors.append(
            f"[claim-as-verb:self-test] expected 0 verb hits in GOOD fixture, got {len(good_hits)}: {good_hits}"
        )

    if errors:
        for e in errors:
            sys.stderr.write(e + "\n")
        return 1
    print("[claim-as-verb:self-test] OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return run_self_test()
    all_hits: list[tuple[pathlib.Path, int, str, str]] = []
    for path in iter_markdown_files():
        for lineno, rule, line in scan_file(path):
            all_hits.append((path, lineno, rule, line))

    if not all_hits:
        print("[claim-as-verb] OK")
        return 0

    for path, lineno, rule, line in all_hits:
        rel = path.relative_to(REPO_ROOT)
        sys.stderr.write(f"{rel}:{lineno} [{rule}] {line}\n")
    sys.stderr.write(
        f"\n[claim-as-verb] FAIL: {len(all_hits)} suspicious line(s). "
        f"Use Collect (ETH) / Harvest (tokens) / Withdraw (principal) per "
        f"brand/copy/tone-guide.md.\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
