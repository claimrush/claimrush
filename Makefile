.PHONY: deps deps-force build codesize-check test test-unit test-integration test-invariants test-heavy clean analytics-lint subgraph-lint solidity-policy-lint abi-lint deployment-manifest-keys-check deployment-manifest-schema-parity-check deployment-role-reachability-check sol-test-parity-check manuals-truthiness-check test-file-coverage-check \
	check-deployments-sync check-manifest-sync \
	sync-docs-deployments check-docs-deployments abis-export abis-check \
	abi-sanity abi-event-schema abi-strict-mode subgraph-abi-parity manifest-schema-parity docs-indexes-truthiness-check gates-docs gates-abis gates \
	agents-build agents-replay-fixture agents-test gates-agents \
	skills-build gates-skills \
	subgraph-schema-check subgraph-live-runtime-readiness-check finalize-genesis poke-local \
	release-docs-consistency-check public-markdown-paths-check public-markdown-commands-check public-workflow-resolution-check public-doc-private-refs-check public-file-ledger public-release-surface-checks \
	slither gas-snapshot gas-snapshot-check semgrep aderyn echidna-coverage-acceptance-self-check gates-security \
	subgraph-derived-event-kinds subgraph-doc-event-checklist-check subgraph-manifest-sync-check subgraph-bonus-rollup-semantics-check

# ============================================================
# Security & correctness scanning
# ============================================================

# Slither static analysis (requires: python3 -m pip install "slither-analyzer==0.11.5")
#
# Runs Slither against the Solidity source, excluding tests/scripts/vendored libs.
# Fails on high severity findings (configured in slither.config.json).
# Reports saved to slither-reports/.
slither: deps
	@mkdir -p slither-reports
	bash scripts/slither_foundry_build.sh
	slither . \
		--config-file slither.config.json \
		--foundry-ignore-compile \
		--json slither-reports/results.json \
		--checklist
	@echo "OK: slither passed"

# Gas snapshot baseline (forge snapshot)
#
# Generates .gas-snapshot for committed regression tracking.
# Run this locally after gas-affecting changes and commit .gas-snapshot.
gas-snapshot: deps
	forge snapshot --snap .gas-snapshot
	@echo "OK: .gas-snapshot updated - review and commit"

# Gas snapshot regression check
#
# Compares current gas usage against the committed .gas-snapshot baseline.
# Fails if any test's gas increases by more than GAS_TOLERANCE_PCT (default 10%).
GAS_TOLERANCE_PCT ?= 10
gas-snapshot-check: deps
	@if [ ! -f .gas-snapshot ]; then \
		echo "WARN: No .gas-snapshot baseline found. Run 'make gas-snapshot' first."; \
		exit 0; \
	fi
	forge snapshot --snap .gas-snapshot-new
	@FAILED=0; \
	while IFS= read -r line; do \
		TEST=$$(echo "$$line" | sed 's/ (gas: .*//'); \
		NEW_GAS=$$(echo "$$line" | grep -oP 'gas: \K[0-9]+'); \
		[ -z "$$NEW_GAS" ] || [ -z "$$TEST" ] && continue; \
		OLD_LINE=$$(grep -F "$$TEST" .gas-snapshot 2>/dev/null || true); \
		[ -z "$$OLD_LINE" ] && { echo "  [NEW]  $$TEST: $$NEW_GAS gas"; continue; }; \
		OLD_GAS=$$(echo "$$OLD_LINE" | grep -oP 'gas: \K[0-9]+'); \
		[ -z "$$OLD_GAS" ] || [ "$$OLD_GAS" -eq 0 ] && continue; \
		DELTA=$$((NEW_GAS - OLD_GAS)); \
		PCT=$$((( DELTA * 100 ) / OLD_GAS)); \
		if [ "$$PCT" -gt "$(GAS_TOLERANCE_PCT)" ]; then \
			echo "  [FAIL] $$TEST: $$OLD_GAS -> $$NEW_GAS (+$${PCT}%)"; \
			FAILED=1; \
		fi; \
	done < .gas-snapshot-new; \
	rm -f .gas-snapshot-new; \
	if [ "$$FAILED" -eq 1 ]; then \
		echo "ERROR: Gas regression exceeds $(GAS_TOLERANCE_PCT)% tolerance."; \
		echo "If intentional: make gas-snapshot && git add .gas-snapshot"; \
		exit 1; \
	fi; \
	echo "OK: No gas regressions beyond $(GAS_TOLERANCE_PCT)% tolerance."

# Semgrep (requires: python3 -m pip install "semgrep==1.152.0")
#
# Runs targeted custom rules from .semgrep.yml against Solidity + TypeScript.
# Focused on security & correctness; not a style linter.
semgrep:
	@if ! command -v semgrep >/dev/null 2>&1; then \
		echo "ERROR: semgrep is not installed or not on PATH."; \
		echo "Install one of:"; \
		echo "  - pipx install semgrep==1.152.0"; \
		echo "  - python3 -m pip install --user semgrep==1.152.0"; \
		echo "  - brew install semgrep"; \
		exit 127; \
	fi
	semgrep scan \
		--config .semgrep.yml \
		--error \
		--verbose \
		--exclude "node_modules" \
		--exclude "lib" \
		--exclude "out" \
		--exclude "dist" \
		--exclude "build" \
		--exclude ".next" \
		--exclude "generated" \
		src/ keeper/ agents/
	@echo "OK: semgrep passed"

# Aderyn static analysis (requires: aderyn CLI - install via cyfrinup or npm)
#
# Generates a Markdown report into .reports/ (gitignored).
# Reads aderyn.toml for source/exclude config (src/mocks/ excluded).
# Fails CI if any High-severity findings are present.
ADERYN_REPORT := .reports/aderyn-report.md
aderyn: deps
	@mkdir -p .reports
	aderyn --output $(ADERYN_REPORT)
	@if grep -qP '^\| High \| \d+[1-9]' $(ADERYN_REPORT) 2>/dev/null; then \
		echo "FAIL: Aderyn found High-severity issues - see $(ADERYN_REPORT)"; \
		exit 1; \
	fi
	@echo "OK: aderyn passed - report at $(ADERYN_REPORT)"

echidna-coverage-acceptance-self-check:
	python3 scripts/check_echidna_coverage_acceptance.py --self-check

# Combined security gate (all security scanners)
gates-security: slither gas-snapshot-check semgrep aderyn
	@echo "OK: gates-security passed"

# ============================================================

.PHONY: smoke-full-app
smoke-full-app:
	@echo "== SmokeFullApp: requires genesis-finalized local Anvil (run local-e2e first) =="
	@RPC="$${LOCAL_RPC_URL:-http://127.0.0.1:8545}"; \
	CHAIN_ID=$$(cast chain-id --rpc-url "$$RPC" 2>/dev/null || echo ""); \
	if [ "$$CHAIN_ID" != "31337" ] && [ "$$CHAIN_ID" != "1337" ]; then \
		echo "Error: smoke-full-app is dev-only and refuses non-local chains (got '$$CHAIN_ID'). Set LOCAL_RPC_URL to a local Anvil endpoint (chainId 31337 or 1337)."; \
		exit 1; \
	fi; \
	LOCAL_PRIVATE_KEY=$${LOCAL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80} \
	  forge script script/SmokeFullApp.s.sol:SmokeFullApp \
	  --rpc-url "$$RPC" --broadcast -vvv

.PHONY: finalize-genesis
finalize-genesis:
	./scripts/finalize_genesis.sh

.PHONY: finalize-genesis-onchain
finalize-genesis-onchain:
	forge script script/FinalizeGenesis.s.sol:FinalizeGenesis --rpc-url "$$RPC_URL" --broadcast -vvv
	@echo "After genesis finalization, run script/Wire.s.sol:Wire, update aerodrome.claimWethPool.startBlock / aerodrome.lpToken.startBlock, and run scripts/verify_deployment.py."

# DEV ONLY: canonical Anvil account #0 private key (public/test key).
# Never use this key on testnet/mainnet or any environment with real funds.
LOCAL_DEV_ANVIL_PRIVATE_KEY ?= 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Run MaintenanceHub.poke() on local chain (flushes shareholder ETH, checkpoints ve, ticks furnace, etc.)
.PHONY: poke-local
poke-local:
	@MAINTENANCE_HUB=$$(jq -r '.contracts.MaintenanceHub.address' deployments/local.json); \
	if [ "$$MAINTENANCE_HUB" = "null" ] || [ -z "$$MAINTENANCE_HUB" ]; then \
		echo "Error: MaintenanceHub address not found in deployments/local.json"; \
		exit 1; \
	fi; \
	RPC_URL="http://127.0.0.1:8545"; \
	CHAIN_ID=$$(cast chain-id --rpc-url "$$RPC_URL" 2>/dev/null || echo ""); \
	if [ "$$CHAIN_ID" != "31337" ] && [ "$$CHAIN_ID" != "1337" ]; then \
		echo "Error: poke-local is dev-only and expects local Anvil chain id 31337 or 1337 (got '$$CHAIN_ID')."; \
		exit 1; \
	fi; \
	DEADLINE=$$(date -d '+1 hour' +%s 2>/dev/null || date -v+1H +%s); \
	echo "Calling MaintenanceHub.poke() at $$MAINTENANCE_HUB..."; \
	cast send $$MAINTENANCE_HUB \
		"poke((uint256[],uint256))" \
		"([],25)" \
		--private-key "$(LOCAL_DEV_ANVIL_PRIVATE_KEY)" \
		--rpc-url "$$RPC_URL"

# Immutable external dependency pins (supply-chain hardening)
# - Using commit SHAs prevents silently consuming retagged releases.
OZ_CONTRACTS_REF ?= dbb6104ce834628e473d2173bbc9d47f81a9eec3 # OpenZeppelin/openzeppelin-contracts v5.0.2
FORGE_STD_REF ?= 978ac6fadb62f5f0b723c996f64be52eddba6801 # foundry-rs/forge-std v1.8.2
NPM ?= npm
NODE ?= node

deps:
	@mkdir -p lib
	@# Verify existing deps are at the pinned immutable refs (supply-chain hardening).
	@# We write a marker file after install so we can detect drift even when deps are installed with --no-git.
	@if [ -d lib/openzeppelin-contracts ] && [ -n "$$(ls -A lib/openzeppelin-contracts 2>/dev/null)" ]; then \
		if [ -f lib/openzeppelin-contracts/.claimrush-dep-ref ] && grep -qx "$(OZ_CONTRACTS_REF)" lib/openzeppelin-contracts/.claimrush-dep-ref; then \
			echo "deps: lib/openzeppelin-contracts already at pinned ref $(OZ_CONTRACTS_REF); skipping"; \
		else \
			echo "ERROR: lib/openzeppelin-contracts exists but is not pinned to expected ref $(OZ_CONTRACTS_REF)."; \
			echo "       Run 'make deps-force' to reinstall pinned deps."; \
			exit 1; \
		fi; \
	else \
		forge install --no-git OpenZeppelin/openzeppelin-contracts@$(OZ_CONTRACTS_REF) \
			&& echo "$(OZ_CONTRACTS_REF)" > lib/openzeppelin-contracts/.claimrush-dep-ref; \
	fi
	@if [ -d lib/forge-std ] && [ -n "$$(ls -A lib/forge-std 2>/dev/null)" ]; then \
		if [ -f lib/forge-std/.claimrush-dep-ref ] && grep -qx "$(FORGE_STD_REF)" lib/forge-std/.claimrush-dep-ref; then \
			echo "deps: lib/forge-std already at pinned ref $(FORGE_STD_REF); skipping"; \
		else \
			echo "ERROR: lib/forge-std exists but is not pinned to expected ref $(FORGE_STD_REF)."; \
			echo "       Run 'make deps-force' to reinstall pinned deps."; \
			exit 1; \
		fi; \
	else \
		forge install --no-git foundry-rs/forge-std@$(FORGE_STD_REF) \
			&& echo "$(FORGE_STD_REF)" > lib/forge-std/.claimrush-dep-ref; \
	fi

deps-force:
	rm -rf lib/openzeppelin-contracts lib/forge-std
	$(MAKE) deps

build: deps
	forge build
	python3 scripts/check_contract_sizes.py --fail

.PHONY: codesize-check

codesize-check:
	python3 scripts/check_contract_sizes.py --fail

# Default test target excludes fork tests (test/fork/**) and the
# Sepolia-fork drift probe so public CI does not depend on third-party
# RPC availability. Run fork suites explicitly via `make test-fork`
# (Base mainnet) or by setting `BASE_SEPOLIA_RPC_URL` for the floor-drift
# probe. ScriptSafety.t.sol still runs single-threaded on its own pass to
# avoid env-var races with TimelockGovernance.t.sol.
# Note: forge accepts only a single --no-match-path; use brace expansion.
test: deps
	forge test -vvv --no-match-path "test/{ScriptSafety.t.sol,fork/**,*.fork.t.sol}"
	forge test -vvv --match-path "test/ScriptSafety.t.sol" -j 1

# Test grouping helpers (unit/integration/invariants) and a heavier fuzz profile.
test-unit: deps
	forge test -vvv --match-path "test/*.t.sol" \
	  --no-match-path "test/{ScriptSafety.t.sol,*.fork.t.sol}"
	forge test -vvv --match-path "test/ScriptSafety.t.sol" -j 1

test-integration: deps
	forge test -vvv --match-path "test/integration/*.t.sol"

test-invariants: deps
	forge test -vvv --match-path "test/invariants/*.t.sol"

# Heavier fuzz/invariant settings for broader local hardening runs.
# ScriptSafety.t.sol mutates process-global env vars (ADMIN_SAFE,
# TIMELOCK_*, DEPLOYMENTS_MANIFEST_JSON, ...) and races with
# TimelockGovernance.t.sol's testGovernanceScriptSimulationEnvCases when
# the heavy profile widens the test-execution window. Mirror the split
# used by `make test`: run everything else in parallel, then run
# ScriptSafety alone with -j 1. Same pattern, same coverage, no race.
test-heavy: deps
	FOUNDRY_PROFILE=heavy forge test -vvv \
	  --no-match-path "test/{ScriptSafety.t.sol,fork/**,*.fork.t.sol}"
	FOUNDRY_PROFILE=heavy forge test -vvv --match-path "test/ScriptSafety.t.sol" -j 1

clean:
	rm -rf out cache

# Analytics lint (Dune templates + derived leaderboard sync)
analytics-lint:
	bash analytics/scripts/lint_sql.sh

# Agent SDK build (TypeScript)
agents-build:
	$(NPM) -C agents/sdk ci
	cd agents/sdk && $(NODE) node_modules/typescript/bin/tsc -p tsconfig.json

# Offline replay fixture (regression sanity check)
agents-replay-fixture: agents-build
	$(NODE) agents/sdk/dist/examples/replay.js --run-dir agents/sdk/fixtures/replay/empty-run --compare

# Agent SDK unit tests (Node's native test runner against the compiled dist/).
# Runs after agents-build so the tests import the same artifact that ships.
# We use shell-glob expansion (`test/*.test.mjs`) rather than a hand-enumerated
# list so any new test file picked up by the repo is automatically executed
# in CI — the previous enumeration silently skipped new tests, defeating the
# point of the gate.
agents-test: agents-build
	cd agents/sdk && $(NODE) --test test/*.test.mjs

# Agent SDK gates
gates-agents: agents-build agents-test agents-replay-fixture

# OpenClaw / Cursor agent skill build (TypeScript). Depends on agents-build
# because the skill imports the SDK via a `file:` dependency. The skill's
# setup.sh installs and builds both the SDK and the skill, deduplicates
# `viem` so the type identities match, and runs an offline smoke check.
skills-build: agents-build
	bash skills/claimrush/scripts/setup.sh

# Skill type-check gate (no emit).
gates-skills: skills-build
	$(NPM) -C skills/claimrush run lint

# Subgraph lint (schema + manifest sync + ABI/signature parity + mutable wiring semantics + codegen layout + docs checklist parity)
subgraph-lint: subgraph-protocol-wiring-check subgraph-doc-event-checklist-check subgraph-codegen-layout-check subgraph-manifest-sync-check subgraph-manifest-parity-check subgraph-bonus-rollup-semantics-check
	python3 scripts/check_subgraph_schema_vs_doc.py
	python3 scripts/check_subgraph_derived_event_kinds.py
	python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.yaml
	python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.prod.yaml
	python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.staging.yaml
	python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.local.yaml
	python3 scripts/check_subgraph_manifest_entities.py subgraph/subgraph.yaml subgraph/subgraph.prod.yaml subgraph/subgraph.staging.yaml subgraph/subgraph.local.yaml

subgraph-bonus-rollup-semantics-check:
	python3 scripts/check_subgraph_bonus_rollup_semantics.py

# Structural parity between the four shipped subgraph manifests. Only
# network, addresses, startBlock and ABI file paths may diverge.
subgraph-manifest-parity-check:
	python3 scripts/check_subgraph_manifest_parity.py

subgraph-protocol-wiring-check:
	python3 scripts/check_subgraph_protocol_wiring_semantics.py

subgraph-doc-event-checklist-check:
	python3 scripts/check_subgraph_doc_event_checklist.py

subgraph-codegen-layout-check:
	python3 scripts/check_subgraph_codegen_layout.py

subgraph-manifest-sync-check:
	python3 scripts/sync_subgraph_manifest_from_deployments.py --manifest subgraph/subgraph.yaml --deployments deployments/local.json --check
	python3 scripts/sync_subgraph_manifest_from_deployments.py --manifest subgraph/subgraph.local.yaml --deployments deployments/local.json --check
	python3 scripts/sync_subgraph_manifest_from_deployments.py --manifest subgraph/subgraph.prod.yaml --deployments deployments/base_mainnet.json --allow-zero-addresses --allow-start-block-zero --check
	python3 scripts/sync_subgraph_manifest_from_deployments.py --manifest subgraph/subgraph.staging.yaml --deployments deployments/base_sepolia.json --allow-zero-addresses --allow-start-block-zero --check

subgraph-derived-event-kinds:
	python3 scripts/check_subgraph_derived_event_kinds.py

# Release-only live manifest gate. This is intentionally NOT part of `make gates`
# because committed staging/prod deployments may still be placeholders before a
# real network rollout. Run it before any non-local subgraph deploy.
subgraph-live-runtime-readiness-check:
	python3 scripts/check_subgraph_manifest_runtime_readiness.py subgraph/subgraph.prod.yaml subgraph/subgraph.staging.yaml

# Local subgraph schema check (catches schema drift when subgraph not redeployed)
subgraph-schema-check:
	python3 scripts/check_local_subgraph_schema.py

# Docs index + manuals truthiness (links, commands, navigation coverage)
docs-indexes-truthiness-check:
	python3 scripts/check_docs_indexes_truthiness.py

release-docs-consistency-check:
	python3 scripts/check_release_docs_consistency.py

public-markdown-paths-check:
	python3 scripts/check_public_markdown_repo_paths.py

public-markdown-commands-check:
	python3 scripts/check_public_markdown_commands.py

public-workflow-resolution-check:
	python3 scripts/check_public_workflow_resolution.py

public-doc-private-refs-check:
	python3 scripts/check_public_doc_private_surface_refs.py

claim-as-verb-check:
	# Run the embedded regression self-test first. If the scanner's noise-stripper
	# regresses (e.g. ever regains the "strip every word containing 'claim'" bug),
	# the self-test fails loudly BEFORE the real scan prints [OK] on an already
	# clean tree and hides the regression.
	python3 scripts/check_claim_as_verb.py --self-test
	python3 scripts/check_claim_as_verb.py

banned-phrases-check:
	# Narrow brand-voice linter covering the high-confidence banned phrases
	# from brand/copy/tone-guide.md (Anti-patterns table). Motivated by the
	# "How ClaimRush Works" regression that survived Phase-1 because it
	# lived in a docs-site _meta.js label that no prior linter scanned.
	# Scope: docs/manuals/**, docs/spec/**, docs-site/content/**,
	# developers-site/content/**, and frontend/src/messages/en.json.
	# Self-test first so a stripper regression cannot silently turn the
	# gate into a no-op on a clean tree.
	python3 scripts/check_banned_phrases.py --self-test
	python3 scripts/check_banned_phrases.py

public-file-ledger:
	@mkdir -p .reports
	python3 scripts/generate_public_file_ledger.py --repo-root . --output .reports/public-file-ledger.json

public-release-surface-checks: release-docs-consistency-check docs-indexes-truthiness-check manuals-truthiness-check public-markdown-paths-check public-markdown-commands-check public-workflow-resolution-check public-doc-private-refs-check claim-as-verb-check banned-phrases-check

deployment-manifest-keys-check:
	python3 scripts/check_deployment_manifest_contract_keys.py

deployment-manifest-schema-parity-check:
	python3 scripts/check_deployment_manifest_schema_parity.py

deployment-role-reachability-check:
	python3 scripts/check_deployment_role_reachability.py deployments/base_mainnet.json

deployment-manifest-eip55-check:
	python3 scripts/check_deployment_manifest_eip55.py

test-file-coverage-check:
	python3 scripts/check_test_file_coverage.py

# Solidity test coverage parity: every deployable contract has a test file.
sol-test-parity-check:
	python3 scripts/check_solidity_test_coverage_parity.py

# Manuals truthiness: contract/event/ABI references in developer manuals exist.
manuals-truthiness-check:
	python3 scripts/check_manuals_truthiness.py

# Solidity policy lint (errors + constants allowlists)
solidity-policy-lint:
	bash scripts/solidity_policy_lint.sh

# ABI lint (locked event/function shapes used by indexers)
abi-lint:
	python3 scripts/lint_maintenancehub_abi.py

# CI check: fail if any generated deployment artifacts drift from deployments/*.json.
check-deployments-sync:
	bash scripts/sync_deployments_all.sh --check
	python3 scripts/sync_docs_deployments.py --check

check-manifest-sync: check-deployments-sync

# Keep docs-only deployment manifests in sync with the repo source-of-truth.
#
# Source of truth:
# - deployments/*.json
#
# Generated docs:
# - docs/deployments/*.md
sync-docs-deployments:
	python3 scripts/sync_docs_deployments.py --write

# CI check: fail if the committed docs manifests drift from deployments/*.json.
check-docs-deployments:
	python3 scripts/sync_docs_deployments.py --check

# ABI export (Base mainnet)
#
# Regenerates abis/base_mainnet/*.abi.json from Foundry build artifacts.
abis-export:
	$(MAKE) build
	python3 scripts/export_abis.py --network base_mainnet --outdir abis/base_mainnet
	python3 scripts/export_abis.py --network base_sepolia --outdir abis/base_sepolia

# ABI schema check (Base mainnet)
#
# Validates that shipped ABIs match the canonical Dune event schema.
abis-check:
	python3 scripts/check_abis_vs_dune_pack.py --docs docs/analytics/dune-integration-pack-v1.0.0.md --abi-dir abis/base_mainnet
	python3 scripts/check_abis_vs_dune_pack.py --docs docs/analytics/dune-integration-pack-v1.0.0.md --abi-dir abis/base_sepolia

# ABI sanity checks (malformed entries, duplicates)
abi-sanity:
	python3 scripts/check_abi_sanity.py --abi-dir abis/base_mainnet
	python3 scripts/check_abi_sanity.py --abi-dir abis/base_sepolia

# ABI typed event schema check (v1.0.0 spec)
#
# Validates that shipped ABIs match the typed signatures + indexed flags pinned in:
# - docs/spec/spec-v1.0.0.md section 11.2
# - docs/spec/maintenance-hub-spec-v1.0.0.md (MaintenanceHub.Poked)
abi-event-schema:
	python3 scripts/check_abi_event_schema.py --network base_mainnet
	python3 scripts/check_abi_event_schema.py --network base_sepolia

# Strict Mode ABI validation
#
# Validates that shipped ABIs:
# - Do NOT contain forbidden Strict Mode symbols (buyLock, LockBought, etc.)
# - DO contain required Strict Mode functions (listLock, sellLockToFurnace, etc.)
# - DO contain required Strict Mode events (LockListed, LockDelisted)
abi-strict-mode:
	python3 scripts/check_abi_strict_mode.py --abi-dir abis/base_mainnet
	python3 scripts/check_abi_strict_mode.py --abi-dir abis/base_sepolia

# Subgraph ABI parity check
#
# Validates that all event handlers declared in subgraph manifests
# have corresponding event definitions in their referenced ABI files.
subgraph-abi-parity:
	python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.yaml subgraph/subgraph.prod.yaml subgraph/subgraph.staging.yaml subgraph/subgraph.local.yaml

# Enforce that abis/base_mainnet/ and abis/base_sepolia/ expose the same
# set of contracts. Per abis/README.md, v1.0.0 expects identical ABI sets
# across networks; this gate catches silent drift such as a new contract
# being exported for staging but forgotten on mainnet (or vice versa).
abi-set-parity:
	python3 scripts/check_abi_set_parity.py --a abis/base_mainnet --b abis/base_sepolia

# Ensure deployments/<network>.json files share the same key structure.
manifest-schema-parity:
	python3 scripts/check_manifest_schema_parity.py --a deployments/base_mainnet.json --b deployments/base_sepolia.json

# Validate package.public.json (the public-slim root manifest the seed script
# substitutes for the internal package.json). Enforces that scripts reference
# only public-surface targets and reject private-surface paths (docs-site/,
# developers-site/, workers/*, Cloudflare deploy helpers).
public-package-manifest-check:
	python3 scripts/check_public_package_manifest.py

# Readiness gates: docs + manifests.
gates-docs: check-deployments-sync public-release-surface-checks manifest-schema-parity deployment-manifest-keys-check deployment-manifest-schema-parity-check deployment-manifest-eip55-check deployment-role-reachability-check test-file-coverage-check public-package-manifest-check

gates-abis: abi-lint abi-sanity abis-check abi-event-schema abi-strict-mode abi-set-parity subgraph-abi-parity

gates: gates-docs gates-abis solidity-policy-lint analytics-lint subgraph-lint subgraph-schema-check sol-test-parity-check manuals-truthiness-check echidna-coverage-acceptance-self-check

.PHONY: test-fork gate-all

# Foundry fork tests against real Aerodrome on a Base mainnet fork.
#
# Usage:
#   export BASE_MAINNET_RPC_URL=https://...   # Base mainnet RPC URL (Alchemy/QuickNode/etc.)
#   make test-fork
test-fork: deps
	@if [ -z "$${BASE_MAINNET_RPC_URL:-}" ]; then \
		echo "SKIP: BASE_MAINNET_RPC_URL is not set; skipping fork tests."; \
		echo "Tip: export BASE_MAINNET_RPC_URL=<Base mainnet RPC URL> to enable."; \
	else \
		echo "== Foundry fork tests (Base mainnet) =="; \
		FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/*' -vvv; \
	fi

# Pre-unlock dry-run of GenesisLPVault24M.withdrawLp() on a Base mainnet
# fork. Spawns Anvil, impersonates the immutable lpWithdrawRecipient,
# warps past unlockTime, executes the withdrawal, and reports the LP
# and fee-token deltas the recipient would receive at unlock.
#
# Usage:
#   export BASE_MAINNET_RPC_URL=https://...
#   make genesis-lp-withdraw-dry-run
genesis-lp-withdraw-dry-run:
	@if [ -z "$${BASE_MAINNET_RPC_URL:-}" ]; then \
		echo "SKIP: BASE_MAINNET_RPC_URL is not set; skipping Genesis LP dry-run."; \
		echo "Tip: export BASE_MAINNET_RPC_URL=<Base mainnet RPC URL> to enable."; \
	else \
		echo "== Genesis LP withdrawal dry-run (Base mainnet fork) =="; \
		node scripts/genesis_lp_withdraw_dry_run.mjs; \
	fi

# Quarterly accrual monitor for GenesisLPVault24M. Appends a JSONL
# snapshot to monitoring/genesis-lp-accrual.jsonl covering vault LP
# balance, pool.claimable0/1(vault), and lock state. Runs read-only
# against the live network.
#
# Usage:
#   export BASE_MAINNET_RPC_URL=https://...
#   make genesis-lp-accrual-snapshot
genesis-lp-accrual-snapshot:
	@if [ -z "$${BASE_MAINNET_RPC_URL:-}" ]; then \
		echo "SKIP: BASE_MAINNET_RPC_URL is not set; skipping accrual snapshot."; \
		echo "Tip: export BASE_MAINNET_RPC_URL=<Base mainnet RPC URL> to enable."; \
	else \
		echo "== Genesis LP accrual snapshot =="; \
		node scripts/genesis_lp_accrual_monitor.mjs; \
	fi

# Full set of local gates (lint/docs/abi) + forge tests + fork tests.
#
# Usage:
#   export BASE_MAINNET_RPC_URL=https://...   (for fork tests)
#   make gate-all
gate-all:
	python3 scripts/sync_subgraph_manifest_from_deployments.py --manifest subgraph/subgraph.yaml --deployments deployments/local.json
	python3 scripts/sync_subgraph_manifest_from_deployments.py --manifest subgraph/subgraph.local.yaml --deployments deployments/local.json
	$(MAKE) gates
	$(MAKE) test
	$(MAKE) abis-export
	$(MAKE) test-fork
	@echo "OK: gate-all passed"
