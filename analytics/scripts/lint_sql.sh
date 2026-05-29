#!/usr/bin/env bash
set -euo pipefail

# ClaimRush v1.0.0 analytics SQL lint
# - Lightweight sanity checks for Dune templates
# - Intentionally uses only POSIX-ish shell tools (bash/find/grep/awk)
#
# NOTE:
# - This linter covers the supported v1.0.0 Dune SQL templates under `analytics/dune/`.
# - Reference-only templates under `reference/` (ex: Postgres) are intentionally not required here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d analytics ]]; then
  echo "ERROR: expected analytics/ directory at repo root." >&2
  exit 1
fi

fail=0

echo "== Analytics SQL lint =="

die_file() {
  local file="$1"; shift
  echo "ERROR: $file: $*" >&2
  fail=1
}

print_matches() {
  local file="$1"; shift
  local pattern="$1"; shift
  # shellcheck disable=SC2016
  grep -nE "$pattern" "$file" | sed 's/^/  /' || true
}

expect_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: missing required template: $path" >&2
    fail=1
  fi
}

fail_if_exists() {
  local path="$1"
  local msg="$2"
  if [[ -f "$path" ]]; then
    echo "ERROR: non-canonical file present: $path" >&2
    echo "  $msg" >&2
    fail=1
  fi
}

check_from_and_missing_where() {
  local file="$1"

  # Case A: "FROM table AND ..." (same line)
  if grep -nE '^[[:space:]]*FROM[[:space:]]+[^;\n]+[[:space:]]+AND[[:space:]]+' "$file" >/dev/null; then
    die_file "$file" "suspicious 'FROM ... AND ...' (likely missing WHERE)"
    print_matches "$file" '^[[:space:]]*FROM[[:space:]]+[^;\n]+[[:space:]]+AND[[:space:]]+'
  fi

  # Case B: "FROM table" then next non-empty line begins with AND
  local and_line
  and_line="$(awk '
    BEGIN { from = 0 }
    /^[[:space:]]*FROM[[:space:]]/ { from = 1; next }
    from && /^[[:space:]]*$/ { next }
    from && /^[[:space:]]*AND[[:space:]]/ { print NR; exit 0 }
    { from = 0 }
  ' "$file" || true)"
  if [[ -n "$and_line" ]]; then
    die_file "$file" "suspicious 'FROM' followed by 'AND' on next line at line $and_line (likely missing WHERE)"
  fi
}

check_dune_required_placeholders() {
  local file="$1"

  if ! grep -q '{{LIMIT}}' "$file"; then
    die_file "$file" "missing required Dune parameter {{LIMIT}}"
  fi
  if ! grep -q '{{OFFSET}}' "$file"; then
    die_file "$file" "missing required Dune parameter {{OFFSET}}"
  fi
  if ! grep -qE '{{[A-Z0-9_]+_START_BLOCK}}' "$file"; then
    die_file "$file" "missing start block filter parameter (expected a {{*_START_BLOCK}} placeholder for performance)"
  fi
}


# Returns 0 if the template enforces a start-block filter on evt_block_number.
#
# Accepted patterns:
#   1) evt_block_number >= {{SINGLE_START_BLOCK}}
#   2) evt_block_number >= LEAST({{A_START_BLOCK}}, {{B_START_BLOCK}}, ...)
#   3) evt_block_number >= GREATEST({{A_START_BLOCK}}, {{B_START_BLOCK}}, ...)
#
# The linter intentionally allows LEAST/GREATEST so multi-registry deployments can
# keep correct semantics without weakening the query to satisfy CI.
has_evt_block_number_start_block_filter() {
  local file="$1"

  # Grep works line-by-line, so we squash the file into one line (and strip SQL
  # line comments) to support multi-line expressions in WHERE clauses.
  local squashed
  squashed="$(awk '{
    sub(/--.*/, "")
    gsub(/[[:space:]]+/, " ")
    printf "%s ", $0
  } END { print "" }' "$file")"

  # Pattern 1: evt_block_number >= {{*_START_BLOCK}}
  if printf '%s\n' "$squashed" | grep -qiE 'evt_block_number[[:space:]]*>=[[:space:]]*{{[A-Z0-9_]+_START_BLOCK}}'; then
    return 0
  fi

  # Pattern 2/3: evt_block_number >= LEAST/GREATEST({{...}}, {{...}}, ...)
  if printf '%s\n' "$squashed" | grep -qiE 'evt_block_number[[:space:]]*>=[[:space:]]*(LEAST|GREATEST)[[:space:]]*\([[:space:]]*{{[A-Z0-9_]+_START_BLOCK}}[[:space:]]*,[[:space:]]*{{[A-Z0-9_]+_START_BLOCK}}([[:space:]]*,[[:space:]]*{{[A-Z0-9_]+_START_BLOCK}})*[[:space:]]*\)'; then
    return 0
  fi

  return 1
}
check_dune_start_block_filter_clause() {
  local file="$1"

  # Leaderboard #4 is a snapshot query that consumes a view.
  # The view builder (not this template) should enforce evt_block_number >= {{VECLAIMNFT_START_BLOCK}}.
  if grep -q '<VE_SNAPSHOT_VIEW>' "$file"; then
    return
  fi

  if ! has_evt_block_number_start_block_filter "$file"; then
    die_file "$file" "missing start block filter clause (expected: evt_block_number >= {{*_START_BLOCK}} or evt_block_number >= LEAST/GREATEST({{*_START_BLOCK}}, {{*_START_BLOCK}}, ...))"
  fi
}

check_dune_panel_start_block_filter_clause() {
  local file="$1"

  # Panels are allowed to be aggregate-only (no LIMIT needed), but
  # any panel that touches decoded event tables should filter by start block.
  if ! grep -qE '{{[A-Z0-9_]+_START_BLOCK}}' "$file"; then
    die_file "$file" "missing start block placeholder (expected a {{*_START_BLOCK}} placeholder)"
    return
  fi

  if ! has_evt_block_number_start_block_filter "$file"; then
    die_file "$file" "missing start block filter clause (expected: evt_block_number >= {{*_START_BLOCK}} or evt_block_number >= LEAST/GREATEST({{*_START_BLOCK}}, {{*_START_BLOCK}}, ...))"
  fi
}

check_config_example_has_dune_start_blocks() {
  local config="analytics/config.example.env"

  if [[ ! -f "$config" ]]; then
    echo "ERROR: missing $config" >&2
    fail=1
    return
  fi

  # Ensure every Dune {{*_START_BLOCK}} placeholder is represented in the example config.
  # This keeps templates + config.example.env in sync.
  local vars
  vars="$(grep -RohE '{{[A-Z0-9_]+_START_BLOCK}}' analytics/dune 2>/dev/null \
    | sed 's/[{}]//g' \
    | sort -u)"

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    if ! grep -qF "${var}=" "$config"; then
      echo "ERROR: $config: missing required var ${var} (referenced by Dune templates)" >&2
      fail=1
    fi
  done <<< "$vars"
}

# 1) Ensure the canonical leaderboard file set exists (v1.0.0)
# Dune leaderboards (numbered 01-08 to match spec leaderboards #1-#8)
for dur in 24h 7d 30d lifetime; do
  expect_file "analytics/dune/leaderboards/01_top_king_claim_mined_${dur}.sql"
  expect_file "analytics/dune/leaderboards/02_longest_reign_${dur}.sql"
  expect_file "analytics/dune/leaderboards/03_most_takeovers_count_${dur}.sql"
  expect_file "analytics/dune/leaderboards/04_top_eth_spent_takeovers_${dur}.sql"
  expect_file "analytics/dune/leaderboards/05_top_royalties_claimed_${dur}.sql"
  expect_file "analytics/dune/leaderboards/07_top_furnace_claim_sent_${dur}.sql"
  expect_file "analytics/dune/leaderboards/08_top_furnace_eth_sent_${dur}.sql"
done
expect_file "analytics/dune/leaderboards/06_top_barons_by_ve_current.sql"

# Required UI lists
expect_file "analytics/dune/ui_lists/recent_reigns_finalized.sql"

# Disallow legacy / non-canonical leaderboard filenames.
# These names belong to the deprecated 9-board pack or earlier misnumbered drafts;
# keeping them out of the canonical folder prevents accidental copy/paste of the wrong leaderboard IDs.
for dur in 24h 7d 30d lifetime; do
  fail_if_exists "analytics/dune/leaderboards/01_top_king_eth_earned_${dur}.sql" \
    "Use: analytics/dune/leaderboards/01_top_king_claim_mined_${dur}.sql (spec #1 metric is totalClaimMined)"
  fail_if_exists "analytics/dune/leaderboards/02_top_eth_spent_takeovers_${dur}.sql" \
    "Use: analytics/dune/leaderboards/04_top_eth_spent_takeovers_${dur}.sql (spec #4)"
  fail_if_exists "analytics/dune/leaderboards/05_top_barons_claim_locked_${dur}.sql" \
    "Removed: not part of the 8-board spec."
  fail_if_exists "analytics/dune/leaderboards/06_top_barons_${dur}_eth_claimed.sql" \
    "Use: analytics/dune/leaderboards/05_top_royalties_claimed_${dur}.sql (spec #5)"
  fail_if_exists "analytics/dune/leaderboards/07_top_eth_sent_to_furnace_${dur}.sql" \
    "Use: analytics/dune/leaderboards/08_top_furnace_eth_sent_${dur}.sql (spec #8)"
  fail_if_exists "analytics/dune/leaderboards/08_best_bonus_rate_${dur}.sql" \
    "Removed: not part of the 8-board spec."
  fail_if_exists "analytics/dune/leaderboards/09_top_claim_received_bonus_${dur}.sql" \
    "Removed: not part of the 8-board spec."
done
fail_if_exists "analytics/dune/leaderboards/04_top_barons_by_ve_current.sql" \
  "Use: analytics/dune/leaderboards/06_top_barons_by_ve_current.sql (spec #6)"
fail_if_exists "analytics/dune/leaderboards/05_top_barons_lifetime_eth_claimed.sql" \
  "Use: analytics/dune/leaderboards/05_top_royalties_claimed_lifetime.sql (spec #5)"
fail_if_exists "analytics/dune/leaderboards/06_top_eth_sent_to_furnace_lifetime.sql" \
  "Use: analytics/dune/leaderboards/08_top_furnace_eth_sent_lifetime.sql (spec #8)"
fail_if_exists "analytics/dune/leaderboards/07_best_bonus_rate_lifetime.sql" \
  "Removed: not part of the 8-board spec."

# 2) Keep config.example.env aligned with placeholders used by Dune templates
check_config_example_has_dune_start_blocks

# 3) Generic SQL hygiene checks for all templates under analytics/
while IFS= read -r -d '' file; do
  check_from_and_missing_where "$file"
done < <(find analytics -type f -name '*.sql' -print0)

# 4) Template parameter + start-block filter checks
shopt -s nullglob

for file in analytics/dune/leaderboards/*.sql analytics/dune/ui_lists/*.sql; do
  check_dune_required_placeholders "$file"
  check_dune_start_block_filter_clause "$file"
done

for file in analytics/dune/panels/*.sql; do
  check_dune_panel_start_block_filter_clause "$file"
done

shopt -u nullglob

if [[ "$fail" -ne 0 ]]; then
  echo "== Analytics SQL lint: FAILED ==" >&2
  exit 1
fi

echo "== Analytics SQL lint: OK =="
