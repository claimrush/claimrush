# ClaimRush Agents

This folder contains **offchain tooling** for building:
- automated players (bots / AI agents)
- scripted harnesses for local dev
- reusable strategy modules and SDK helpers

Principles
- No protocol rule changes required.
- Prefer canonical inputs:
  - ABIs from `/abis/`
  - deployment manifests from `/deployments/`
- Keep scripts agent friendly:
  - deterministic outputs
  - structured JSON outputs where possible
  - explicit error handling

Packages
- `agents/sdk/` - TypeScript SDK for reading state, building transactions, and subscribing to events.
- `agents/sdk/strategies/` - Example ESM strategy modules for the live agent and replay flows.

Related folders
- Analytics and subgraph indexing docs live under `analytics/` and `subgraph/`.
- `skills/claimrush/` - OpenClaw / Cursor agent skill that wraps this SDK with a chat-friendly CLI and enforces the CRAL safety rules (caps, slippage, deadlines, mainnet `--i-understand` gate, dry-run by default). Run `bash skills/claimrush/scripts/setup.sh` once, then `bash skills/claimrush/scripts/cr.sh --help`.

Prereqs
- Node.js 22 (repo uses `.nvmrc`)

Setup
- Start a local chain and deploy the protocol stack with your preferred workflow so `deployments/local.json` contains live local addresses.
- Install agent SDK deps and build the package:
  - `npm -C agents/sdk install` (triggers the `prepare` script which runs `npm run build`), or
  - `npm -C agents/sdk ci && npm -C agents/sdk run build` (deterministic CI-style install; `npm ci` intentionally skips `prepare`, so build must be explicit).
- Run SDK example against local:
  - `RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:quickstart`

Note
- The SDK ships as a TypeScript source tree; `main`/`exports` in `agents/sdk/package.json` resolve into the compiled `dist/` output. A fresh clone must therefore run `npm run build` once (the `prepare` script does this automatically on `npm install`). All example and test scripts re-invoke `npm run build` before running, so they are safe to run repeatedly.

Docs
- Developer manual: `docs/manuals/developer/agents-and-automation.md`
