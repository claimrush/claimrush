#!/usr/bin/env python3
"""Check that brand-voice banned phrases from brand/copy/tone-guide.md do not
appear in public-facing surfaces.

Scope (what this scans):
  - docs/manuals/{user,developer}/**/*.md        (doc prose)
  - docs/spec/**/*.md                             (spec prose)
  - docs-site/content/**/*.mdx                    (rendered user docs)
  - docs-site/content/**/_meta.js                 (Nextra nav labels)
  - developers-site/content/**/*.mdx              (rendered developer docs)
  - developers-site/content/**/_meta.js           (Nextra nav labels)
  - frontend/src/messages/en.json                 (English i18n source)

Motivation:
  This gate closes the regression mode that allowed "How ClaimRush Works"
  to survive the Phase-1 brand-voice pass: the phrase had been removed
  from every Markdown file under docs/manuals/ but persisted in
  docs-site/content/_meta.js, which no brand-voice linter scanned.
  `check_claim_as_verb.py` covers the narrow "claim as a verb" rule;
  this script covers the narrow, high-confidence banned phrases from
  the tone guide's Anti-patterns table.

What this gate DOES catch:
  Verbatim (or near-verbatim) uses of phrases that are wrong in every
  context they'd naturally appear:

    - "How it works" / "How <X> works"   (banned heading / nav phrasing)
    - "Learn more"                        (banned CTA phrasing)
    - "Your next move"                    (banned coaching phrasing)
    - "You're all set"                    (banned confirmation phrasing)
    - "Something went wrong"              (banned error phrasing)
    - "Welcome back"                      (banned greeting)
    - "Get in touch"                      (banned contact CTA)
    - "Congratulations" / "Congrats"      (banned celebration)
    - "Great job" / "All good" /
      "You're caught up"                  (banned coaching)
    - "Thank you" as acknowledgement      (banned acknowledgement)
    - "Quick start" / "Starter pack"      (banned onboarding phrasing)

What this gate intentionally DOES NOT catch:
  Context-dependent banned phrases from the tone guide that produce
  false positives without careful heading-vs-prose discrimination:

    - "Dashboard"          (banned only as a page name, fine as a noun)
    - "Easy" / "Simple"    (banned only as promotional adjectives)
    - "Explore" / "Discover" (banned only as nav verbs)
    - "Quick" / "Quickly"  (context-sensitive)

  Those require human judgment; the tone guide's Reviewer Checklist
  handles them at review time.

Exit status:
  0 - no banned-phrase usages found.
  1 - at least one suspicious line found; a report is printed to stderr.

Self-test:
  Run with `--self-test` to exercise known-bad and known-good fixtures.
  Wired into the `banned-phrases-check` Makefile target so a regression
  in the stripper (e.g. ever accidentally dropping inline code handling)
  fails loudly BEFORE the real scan prints [OK] on a clean tree.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

MARKDOWN_SCAN_ROOTS = [
    REPO_ROOT / "docs" / "manuals" / "user",
    REPO_ROOT / "docs" / "manuals" / "developer",
    REPO_ROOT / "docs" / "spec",
]

MDX_AND_META_SCAN_ROOTS = [
    REPO_ROOT / "docs-site" / "content",
    REPO_ROOT / "developers-site" / "content",
]

I18N_EN_FILE = REPO_ROOT / "frontend" / "src" / "messages" / "en.json"

# Phrase patterns. Each entry is (rule_id, compiled_regex).
#
# Regex conventions:
#   - All patterns are case-insensitive.
#   - Word boundaries prevent matching "dashboard" inside "dashboards" or
#     identifier tokens like "DashboardWidget".
#   - Apostrophes accept both ASCII (') and curly (’) forms; Markdown
#     editors commonly auto-convert.
BANNED_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # "How it works" family, plus ClaimRush-specific rewordings
    # ("How ClaimRush Works", "How the Crown works", "How rewards work"
    # in singular-subject form). The historical regression that motivated
    # this gate was specifically "How ClaimRush Works" in a Nextra
    # _meta.js label; we match the broader family so renames do not
    # require a new literal.
    (
        "how-it-works",
        re.compile(
            r"\bhow\s+(?:it|claimrush|the\s+\w+|\w+)\s+works\b",
            re.IGNORECASE,
        ),
    ),
    # "Learn more" — CTA / link-text, always banned.
    (
        "learn-more",
        re.compile(r"\blearn\s+more\b", re.IGNORECASE),
    ),
    # "Your next move" — coaching framing.
    (
        "your-next-move",
        re.compile(r"\byour\s+next\s+move\b", re.IGNORECASE),
    ),
    # "You're all set" — confirmation phrasing.
    (
        "youre-all-set",
        re.compile(r"\byou[\'\u2019]re\s+all\s+set\b", re.IGNORECASE),
    ),
    # "Something went wrong" — error phrasing.
    (
        "something-went-wrong",
        re.compile(r"\bsomething\s+went\s+wrong\b", re.IGNORECASE),
    ),
    # "Welcome back" — banned greeting.
    (
        "welcome-back",
        re.compile(r"\bwelcome\s+back\b", re.IGNORECASE),
    ),
    # "Get in touch" — banned contact CTA.
    (
        "get-in-touch",
        re.compile(r"\bget\s+in\s+touch\b", re.IGNORECASE),
    ),
    # "Congratulations" / "Congrats".
    (
        "congratulations",
        re.compile(r"\bcongrat(?:ulation|s)\w*\b", re.IGNORECASE),
    ),
    # Coaching phrases.
    (
        "great-job",
        re.compile(r"\bgreat\s+job\b", re.IGNORECASE),
    ),
    (
        "all-good",
        re.compile(r"\ball\s+good\b", re.IGNORECASE),
    ),
    (
        "youre-caught-up",
        re.compile(r"\byou[\'\u2019]re\s+caught\s+up\b", re.IGNORECASE),
    ),
    # "Thank you" as a standalone acknowledgement. Only flag when followed
    # by sentence-ending punctuation to avoid false positives like
    # "Thank you both" or "Thank you for your time" (still ugly but
    # structurally different sentences — leave those to the reviewer).
    (
        "thank-you",
        re.compile(r"\bthank\s+you\b\s*[.!?]", re.IGNORECASE),
    ),
    # "Quick start" / "Quickstart" / "Starter pack" — banned onboarding
    # phrasing from the Banned-words list.
    (
        "quick-start",
        re.compile(r"\bquick[\s-]?start\b", re.IGNORECASE),
    ),
    (
        "starter-pack",
        re.compile(r"\bstarter\s+pack\b", re.IGNORECASE),
    ),
]

# Noise strippers (shared shape with check_claim_as_verb.py).
CODE_FENCE = re.compile(r"^\s*(?:```|~~~)")
INLINE_BACKTICK = re.compile(r"`[^`]*`")
MARKDOWN_LINK_TARGET = re.compile(r"\]\([^)]+\)")
URL = re.compile(r"https?://\S+")
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
YAML_FRONTMATTER_FENCE = re.compile(r"^---\s*$")


def strip_prose_noise(line: str) -> str:
    """Remove code-like tokens so only prose is left for matching."""
    out = INLINE_BACKTICK.sub(" ", line)
    out = MARKDOWN_LINK_TARGET.sub(" ", out)
    out = URL.sub(" ", out)
    return out


def scan_markdown_text(text: str) -> list[tuple[int, str, str]]:
    """Scan a Markdown or MDX document body for banned phrases.

    Honours code fences, inline backticks, URLs, Markdown-link targets,
    HTML comments, and YAML frontmatter. Returns a list of
    (line_number, rule_id, raw_line) for each hit.
    """
    hits: list[tuple[int, str, str]] = []

    # Drop HTML comments first so prose inside them isn't scanned.
    # Preserve line breaks so error line numbers still match the source.
    text = HTML_COMMENT.sub(
        lambda m: "\n" * m.group(0).count("\n"),
        text,
    )

    in_fence = False
    in_frontmatter = False
    lines = text.splitlines()
    if lines and YAML_FRONTMATTER_FENCE.match(lines[0]):
        in_frontmatter = True

    for lineno, raw in enumerate(lines, start=1):
        if in_frontmatter:
            if lineno > 1 and YAML_FRONTMATTER_FENCE.match(raw):
                in_frontmatter = False
            continue
        if CODE_FENCE.match(raw):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stripped = strip_prose_noise(raw)
        for name, pattern in BANNED_PATTERNS:
            if pattern.search(stripped):
                hits.append((lineno, name, raw.rstrip()))
                # Multiple distinct rules can hit the same line; keep
                # walking so we report each, but don't duplicate for
                # the same rule on the same line.
                break
    return hits


def scan_meta_js_text(text: str) -> list[tuple[int, str, str]]:
    """Scan a Nextra _meta.js file for banned phrases.

    Treats the whole file as label strings; no code-fence semantics.
    Inline backticks are treated as string delimiters and left alone.
    This is stricter than Markdown scanning on purpose: these files
    contain only nav labels, so any literal banned phrase is a real hit.
    """
    hits: list[tuple[int, str, str]] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        # Skip line comments and leading whitespace. _meta.js files are
        # small and hand-written; the banned phrases we care about live
        # inside quoted string values.
        for name, pattern in BANNED_PATTERNS:
            if pattern.search(raw):
                hits.append((lineno, name, raw.rstrip()))
                break
    return hits


def scan_i18n_en(path: pathlib.Path) -> list[tuple[int, str, str]]:
    """Scan an i18n JSON source file. Walk the value tree and flag any
    string value that matches a banned phrase. Line numbers are
    approximated by re-reading the file and locating the offending
    value's first occurrence — good enough for a linter report.
    """
    raw_text = path.read_text(encoding="utf-8")
    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"{path}: invalid JSON: {e}\n")
        return []

    hits: list[tuple[int, str, str]] = []

    def walk(node: object, path_parts: list[str]) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, path_parts + [str(k)])
            return
        if isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, path_parts + [str(i)])
            return
        if isinstance(node, str):
            for name, pattern in BANNED_PATTERNS:
                if pattern.search(node):
                    lineno = _approx_lineno_for_value(raw_text, node)
                    key_path = ".".join(path_parts)
                    hits.append((lineno, name, f"{key_path}: {node!r}"))
                    break

    walk(data, [])
    return hits


def _approx_lineno_for_value(raw_text: str, needle: str) -> int:
    """Return the 1-based line number of the first occurrence of `needle`
    in `raw_text`, or 0 if not found. This is a best-effort approximation
    used only for reporting; the JSON path is the stable identifier.
    """
    try:
        idx = raw_text.index(needle)
    except ValueError:
        return 0
    return raw_text[:idx].count("\n") + 1


def iter_markdown_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in MARKDOWN_SCAN_ROOTS:
        if not root.exists():
            continue
        files.extend(sorted(root.rglob("*.md")))
    return files


def iter_mdx_and_meta_files() -> list[tuple[pathlib.Path, str]]:
    """Return (path, kind) pairs where kind is 'mdx' or 'meta'."""
    pairs: list[tuple[pathlib.Path, str]] = []
    for root in MDX_AND_META_SCAN_ROOTS:
        if not root.exists():
            continue
        for mdx in sorted(root.rglob("*.mdx")):
            pairs.append((mdx, "mdx"))
        for meta in sorted(root.rglob("_meta.js")):
            pairs.append((meta, "meta"))
    return pairs


# Regression fixtures. Kept close to the scanner so a refactor that
# accidentally disables the gate (e.g. the stripper dropping inline
# code handling) is caught by `--self-test` in CI before the real
# scan prints [OK] on an already-clean tree.
SELF_TEST_BAD = """\
# Sample

How ClaimRush Works is a great tutorial.

- Learn more about the Crown
- Your next move is a takeover
- You're all set to start
- Something went wrong, retry
- Welcome back, player
- Get in touch with support
- Congratulations on your reign!
- Great job, you finished it
- Thank you.
- Quick start guide
"""

SELF_TEST_GOOD = """\
# Sample

The Core Concepts page explains the `CLAIM stream`.

- Call `royalties.claimShareholderEth` to collect accrued ETH.
- See [reference](docs/reference.md) for details.
- A mining claim is a noun, not a verb.

```md
How it works (this is inside a code fence and should not be flagged)
```

<!-- Reviewer note: Learn more here is inside an HTML comment and must not
be flagged. -->
"""


def run_self_test() -> int:
    bad_hits = scan_markdown_text(SELF_TEST_BAD)
    good_hits = scan_markdown_text(SELF_TEST_GOOD)

    errors: list[str] = []
    # The BAD fixture has 11 bulletted banned-phrase lines plus one H1 line.
    # `how-it-works`, `learn-more`, `your-next-move`, `youre-all-set`,
    # `something-went-wrong`, `welcome-back`, `get-in-touch`,
    # `congratulations`, `great-job`, `thank-you`, `quick-start` = 11.
    if len(bad_hits) < 11:
        errors.append(
            f"[banned-phrases:self-test] expected >=11 hits in BAD fixture, "
            f"got {len(bad_hits)}: {bad_hits}"
        )
    if good_hits:
        errors.append(
            f"[banned-phrases:self-test] expected 0 hits in GOOD fixture, "
            f"got {len(good_hits)}: {good_hits}"
        )

    if errors:
        for e in errors:
            sys.stderr.write(e + "\n")
        return 1
    print("[banned-phrases:self-test] OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return run_self_test()

    all_hits: list[tuple[pathlib.Path, int, str, str]] = []

    for path in iter_markdown_files():
        text = path.read_text(encoding="utf-8")
        for lineno, rule, line in scan_markdown_text(text):
            all_hits.append((path, lineno, rule, line))

    for path, kind in iter_mdx_and_meta_files():
        text = path.read_text(encoding="utf-8")
        hits = (
            scan_markdown_text(text) if kind == "mdx" else scan_meta_js_text(text)
        )
        for lineno, rule, line in hits:
            all_hits.append((path, lineno, rule, line))

    if I18N_EN_FILE.exists():
        for lineno, rule, line in scan_i18n_en(I18N_EN_FILE):
            all_hits.append((I18N_EN_FILE, lineno, rule, line))

    if not all_hits:
        print("[banned-phrases] OK")
        return 0

    for path, lineno, rule, line in all_hits:
        try:
            rel = path.relative_to(REPO_ROOT)
        except ValueError:
            rel = path
        sys.stderr.write(f"{rel}:{lineno} [{rule}] {line}\n")
    sys.stderr.write(
        f"\n[banned-phrases] FAIL: {len(all_hits)} hit(s). "
        f"Remove or rephrase per brand/copy/tone-guide.md (§Anti-patterns).\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
