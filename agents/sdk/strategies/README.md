# Agent strategy modules (templates)

This folder contains **example strategy modules** you can load via:

- `npm -C agents/sdk run example:agent -- --strategy-module ./strategies/<file>.mjs`
- `npm -C agents/sdk run example:replay -- --strategy-module ./strategies/<file>.mjs`

Strategy modules are **ESM** and must export one of:

- `export const strategies = [ ... ]`
- `export default [ ... ]`
- `export const strategy = { ... }`
- `export default { ... }`

These examples import from `@claimrush/agent-sdk` using a package self-reference.
That works when running inside this repo (the package is the SDK itself).

Tips

- Keep strategies **pure**: decide actions from `snapshot` + config, don’t send txs.
- Use `stopOnActions: true` for “first match wins” behavior.
- In production, prefer running custom strategies **before** the built-in policy strategy.
