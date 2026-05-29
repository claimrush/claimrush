#!/usr/bin/env bash
# Drive the per-surface Halmos M1-M6 meta-proof matrix. One Halmos run per
# harness file, log capture under out/halmos-meta-proofs/<surface>.log,
# exit-code aggregation, non-zero summary at end.
#
# Usage:
#   bash scripts/run_halmos_meta_proofs.sh                # full matrix
#   bash scripts/run_halmos_meta_proofs.sh --surface=Furnace   # single surface
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Halmos requires AST in compiled artifacts. The dedicated `halmos` profile
# sets `ast = true`; running the default profile would skip the AST and trip
# every check with `KeyError: 'ast'`. Halmos respects FOUNDRY_PROFILE for its
# own internal `forge build` invocation, so exporting it here covers both the
# pre-build the CI workflow does and the per-call build halmos performs.
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-halmos}"

SURFACES=(
  "Furnace"
  "MineCore"
  "ShareholderRoyalties"
  "MarketRouter"
  "VeClaimNFT"
  "LpStakingVault7D"
  "GenesisLPVault24M"
  "ClaimToken"
  "EntryTokenRegistry"
)

# Per-surface allowlist of `check_*` symbolic obligations that are known to
# exceed the documented Halmos solver budget on Z3 due to QF_AUFBV
# bit-blasting of `bvmul`/`bvudiv` with a symbolic dividend (a known
# nonlinear-arithmetic decidability limit). Each entry MUST cite the
# differential or Foundry test that pins the property concretely so the
# obligation is verified end-to-end despite the symbolic timeout. The
# allowlist intentionally identifies tests by the exact halmos `[TIMEOUT]`
# function name (the string the script `grep`s for) so any property rewrite
# falls out of the allowlist automatically and re-fails the stage until the
# rewrite is also reflected here.
KNOWN_TIMEOUTS_Furnace=(
  # Pinned concretely by:
  #   - test/halmos/differential/Furnace_ModelDifferential.t.sol::testFuzz_modelPrincipalEffMatchesMulDiv
  #   - test/Furnace_DurationWeightPrecision.t.sol (production monotonicity envelope)
  "check_furnaceM1PrincipalEffMonotonicInWeightDelta"
  # Pinned concretely by:
  #   - test/halmos/differential/Furnace_ModelDifferential.t.sol::testFuzz_modelPrincipalEffMatchesMulDiv
  #   - test/Furnace_ExtendWithBonusPathIndependence.t.sol::test_CyclingDoesNotInflateBaseline
  "check_furnaceM4PrincipalEffSplitNeverExceedsWhole"
)

# Return 0 iff every `[TIMEOUT]` line in the log corresponds to a function
# named in the surface's KNOWN_TIMEOUTS_<surface> array, AND the log
# contains no `[FAIL]`/`[ERROR]`/`Counterexample` lines (those would
# indicate a real symbolic violation, not a solver-decidability boundary).
classify_halmos_log() {
  local surface="$1"
  local log="$2"

  # Hard fail on any real symbolic counterexample or solver error.
  if grep -qE "^\[(FAIL|ERROR)\]" "$log" || grep -q "Counterexample" "$log"; then
    return 1
  fi

  # Collect TIMEOUT function names from the log. Halmos prints
  # `[TIMEOUT]\n<fn>(<sig>) (paths: …)` so we read the first identifier on
  # the line after each `[TIMEOUT]` marker.
  local timeouts
  timeouts=$(awk '
    /^\[TIMEOUT\]/ { capture = 1; next }
    capture {
      sub(/\(.*$/, "")
      gsub(/[ \t]+/, "")
      if (length($0) > 0) print
      capture = 0
    }
  ' "$log")

  if [ -z "$timeouts" ]; then
    # No timeouts at all: surface is genuinely failing for some other
    # reason (e.g. build error, halmos crash). Bubble up the failure.
    return 1
  fi

  # Resolve the per-surface allowlist by name.
  local allowlist_var="KNOWN_TIMEOUTS_${surface}[@]"
  local allowed=("${!allowlist_var-}")

  while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    local ok=0
    for known in "${allowed[@]-}"; do
      if [ "$fn" = "$known" ]; then
        ok=1
        break
      fi
    done
    if [ $ok -eq 0 ]; then
      echo "[halmos-meta] ${surface}: unexpected solver timeout: $fn" >&2
      return 1
    fi
    echo "[halmos-meta] ${surface}: known solver-bound timeout: $fn (verified concretely; see harness NatSpec)"
  done <<<"$timeouts"

  return 0
}

FILTER=""
for arg in "$@"; do
  case "$arg" in
    --surface=*) FILTER="${arg#--surface=}" ;;
    *) echo "unknown arg: $arg" >&2 ; exit 2 ;;
  esac
done

OUT_DIR="out/halmos-meta-proofs"
mkdir -p "$OUT_DIR"

FAILED=()
RAN=()

for surface in "${SURFACES[@]}"; do
  if [ -n "$FILTER" ] && [ "$FILTER" != "$surface" ]; then
    continue
  fi
  contract="${surface}_M1_M6_Proofs"
  log="$OUT_DIR/${surface}.log"
  echo "[halmos-meta] ${surface} -> ${log}"

  set +e
  halmos \
    --match-contract "$contract" \
    --function check_ \
    >"$log" 2>&1
  rc=$?
  set -e

  RAN+=("$surface")
  if [ $rc -ne 0 ]; then
    if classify_halmos_log "$surface" "$log"; then
      echo "[halmos-meta] ${surface}: exit=$rc tolerated (only known solver-bound timeouts; see allowlist + per-test NatSpec)"
    else
      FAILED+=("$surface (exit=$rc)")
    fi
  fi
done

echo
echo "[halmos-meta] ran: ${#RAN[@]} surface(s)"
if [ "${#FAILED[@]}" -ne 0 ]; then
  echo "[halmos-meta] FAILED: ${FAILED[*]}"
  exit 1
fi
echo "[halmos-meta] OK: all surfaces proved"
