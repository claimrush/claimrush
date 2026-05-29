# ClaimToken implementer checklist (derived, v1.0.0)

This checklist is a **derived helper**. It MUST NOT override the canonical v1.0.0 spec.

Reference contract: `src/ClaimToken.sol` (implements `IClaimToken`).

Canonical sources:
- `docs/spec/spec-v1.0.0.md` §3 (ClaimToken)
- `src/lib/Constants.sol` (constants)
- The invariants document (supply + authorization invariants)

---

## 0) Scope

`ClaimToken` is the ERC20 token for ClaimRush.

Non-negotiables (v1.0.0):

- No premine. `totalSupply()` starts at `0`.
- No fees, no rebasing, no reflection.
- Minting MUST be callable only by MineCore.
- A true burn method is available (reduces total supply).

---

## 1) ERC20 identity and baseline behavior

Implement:

- Name: `ClaimRush`
- Symbol: `CLAIM`
- Decimals: `18`

MUST:

- Follow standard ERC20 semantics for `transfer`, `approve`, `transferFrom`.
- Emit standard `Transfer` and `Approval` events.

MUST NOT:

- Add protocol fees, tax, or hooks that change balances on transfer.

**Required restriction (reference implementation):** any transfer or mint whose **destination** is `address(this)` or `address(_wiringProbe)` MUST revert with `Errors.TransfersRestricted()` (override `_update` per OZ `ERC20` v5). Standard allowance/balance checks remain.

---

## 2) Wiring and config freeze

The v1.0.0 wiring model uses a 2-step setup.

### 2.1 `setMineCore(address _mineCore)`

Signature (reference): `function setMineCore(address _mineCore) external onlyOwner whenNotFrozen`

MUST:

- Be callable by admin during Phase B wiring (`onlyOwner`).
- Store the MineCore address used by `mint`.
- Reject `address(0)` or a non-contract address (`Errors.ZeroAddress`, `Errors.NotAContract`).
- Validate full MineCore identity at setter time via `_checkFreezeTimeMineCoreIdentity`: dual-context `claim() == address(this)` (from both ClaimToken and WiringProbe), `emissionStartTime() != 0`, and `GENESIS_ACCRUAL_DURATION() != 0` (`Errors.WiringMismatch` on any mismatch).
- Emit `Events.MineCoreChanged(oldMineCore, _mineCore)` on success.
- Be disallowed after config is frozen (`Errors.ConfigFrozen` via `whenNotFrozen`).

### 2.2 `freezeConfig()`

Signature (reference): `function freezeConfig() external onlyOwner whenNotFrozen`

MUST:

- Permanently freeze wiring/config fields (`configFrozen = true`).
- Be callable by admin during Phase C wiring.
- Reject unset, zero, or non-contract `mineCore` (`Errors.ZeroAddress`, `Errors.NotAContract`).
- Verify MineCore identity before freezing via `_checkFreezeTimeMineCoreIdentity`: dual-context `claim() == address(this)` (from both ClaimToken and WiringProbe), `emissionStartTime() != 0`, and `GENESIS_ACCRUAL_DURATION() != 0` (`Errors.WiringMismatch` on any mismatch).
- Emit `Events.ConfigFrozen()` on success.

### 2.3 `renounceOwnership()` (OpenZeppelin `Ownable2Step`)

Reference behavior: `renounceOwnership()` is `onlyOwner` but MUST revert with `Errors.NotAuthorized()` until `configFrozen == true`, after which it delegates to `Ownable2Step` (prevents renouncing before wiring is finalized).

---

## 3) Minting (MineCore only)

### 3.1 `mint(address to, uint256 amount)`

Signature (reference): `function mint(address to, uint256 amount) external onlyMineCore`

MUST:

- Restrict caller: caller MUST be the configured MineCore (`Errors.OnlyMineCore`).
- Reject `to == address(0)` (`Errors.ZeroAddress`), `to == address(this)` (`Errors.TransfersRestricted`), and `amount == 0` (`Errors.AmountZero`).
- Mint increases:
  - `totalSupply` by `amount`
  - `balanceOf(to)` by `amount`
- Emit `Transfer(address(0), to, amount)`.

MUST NOT:

- Allow any other contract to mint.
- Mint to `address(0)` or to the token contract address.

Clarification (non-binding):

- MineCore is responsible for splitting emissions between:
  - the King stream (minted to the King)
  - the Furnace stream (minted to the Furnace)

---

## 4) Burning (required)

### 4.1 `burn(uint256 amount)` (REQUIRED)

Signature (reference): `function burn(uint256 amount) external`

MUST:

- Burn from `msg.sender`.
- Revert with `Errors.AmountZero()` when `amount == 0`.
- Reduce both:
  - `balanceOf(msg.sender)`
  - `totalSupply`
- Emit `Transfer(msg.sender, address(0), amount)`.

Clarification (non-binding):

- This burn is a true supply reduction (reduces `totalSupply`).

### 4.2 `burnFrom(address account, uint256 amount)` (FORBIDDEN in v1.0.0)

MUST NOT:

- Expose `burnFrom` (or any allowance-based burn method) in the ClaimToken ABI.
- Inherit OpenZeppelin `ERC20Burnable` (it includes `burnFrom`).
- Add any admin/role-based burn that can burn other users' balances.

Constraints (required):

- Canonical reference: `docs/spec/spec-v1.0.0.md` §3.2.
- Allowance-burn semantics are not part of v1.0.0. Any version that introduces them MUST add them to the spec and roles matrix first.

---

## 5) Invariants checklist

MUST hold at all times:

- `totalSupply == sum(balanceOf(all addresses))` (ERC20 accounting correctness).
- Only MineCore can increase supply.
- Only explicit burn methods can decrease supply.
- The token contract balance cannot increase via `transfer`/`transferFrom`/`mint` to `address(this)` (restricted destination).

### 5.1 Custom errors (reference: `src/lib/Errors.sol`)

Implementations aligned with `ClaimToken.sol` SHOULD use: `ZeroAddress`, `NotAContract`, `WiringMismatch`, `ConfigFrozen`, `OnlyMineCore`, `TransfersRestricted`, `AmountZero`, `NotAuthorized` (renounce path), as appropriate.

---

## 6) Minimum tests (Foundry)

Unit tests (minimum):

- Identity
  - `testNameSymbolDecimals`
  - `testTotalSupplyIsZeroOnDeploy`

- Config
  - `testSetMineCoreRejectsZero`
  - `testFreezeConfigPreventsRewiring` (if wiring setters exist)

- Mint authorization
  - `testMintRevertsForNonMineCore`
  - `testMintMintsToRecipientAndIncreasesSupply`

- Burn semantics
  - `testBurnReducesSupplyAndBalance`
  - `testBurnRevertsIfInsufficientBalance`

- Forbidden surface checks
  - `testAbiDoesNotExposeBurnFrom` (read compiled artifact ABI JSON and assert no `burnFrom`)
