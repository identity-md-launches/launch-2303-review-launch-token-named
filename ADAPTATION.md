# IMD launch adaptation: Intelligent Dance Market (IDM)

Launch: Robinhood Chain (chain id 4663), kind `univ4_hook`, IDM paired with native ETH, from
discodirector/idm-hook at `69cddfddd0e0bf5903e3e19eab38aebc70285e3a`. The Foundry project is the
repository root; `foundry.toml`, `remappings.txt`, `lib/` and the vendored dependencies are untouched.

What the launch deploys: `src/SequencerToken.sol` (the launch token) and `src/SequencerHook.sol` (the
hook). `src/PulseTreasury.sol` is the requester's optional post-launch contract and is not deployed by the
launch. SPEC.md section 3, the two packed state words (physical slots 0 and 1), the event and state ABI and
the Solidity test vectors (`spec/vectors.json`, `spec/vectors-v2.json`) are unchanged: `forge test` and
`scripts/validate-vectors.py` pass on the same vector files.

Checks run here: `forge build`, `forge test` with `FOUNDRY_FUZZ_SEED=0xf7cec6e43efa96394060a44d17ffa8baac215dce7381192a20d81bfdf9471bc2`
(208 tests, 11 suites, 0 failed), `python3 scripts/validate-vectors.py` (130 v1 + 554 v2 cases). A scratch
rehearsal of the protected floor flow (hook deployed by CREATE2 from a factory address with a foreign
`tx.origin`, the factory opening ETH/IDM at fee 12500 / spacing 60, a full-range seed, a buy and a sell,
then a zero-liquidity fee collect) also passed; it lived in `test/scratch/` and is not part of the delivery.

## Changes

### 1. `src/SequencerHook.sol`: the paired currency is no longer a constructor argument

Rule: every constructor argument must be a value the manifest can write (`$poolManager`, `$token`,
`$factory`, `$owner`, `$launchNumber` or a fixed number / existing contract); a hand-written zero address
is refused by the manifest check. Audit finding `7f537582` (medium) reproduces: the fourth argument
`address quote_` could only be written as `0x0000…0000` for native ETH, which blocks the launch before
deployment.

Fix (the audit's second suggested form, and the launch reference's own rule that a hook may read the pair
from the PoolKey in `beforeInitialize`):

- Constructor is now `(IPoolManager manager_, address token_, address factory_, uint128 hat_, uint128 glitch_, uint128 snare_)`,
  written by the manifest as `["$poolManager", "$token", "$factory", "1250000000000000", "12500000000000000", "62500000000000000"]`.
  It still makes no chain-state reads and still calls `Hooks.validateHookPermissions`.
- `quote` and `quoteIs0` are bound once in `afterInitialize` from the key the factory opens: the key must
  be sorted, carry this hook, use fee 12500 and spacing 60, come from `$factory`, and contain the token;
  the other currency is the quote (native ETH at this launch, always `currency0`; an ERC20 quote on either
  side still works, as before). They live in storage slot 3 packed with `initialized`; slots 0 and 1 (the
  packed state words) and slot 2 (`poolId`) are where they were.
- `afterSwap`, the rules, events and views are unchanged. Before initialization `whaleThresholdAt(tick)`
  reads with `quoteIs0 == false`; `whaleThreshold()` before initialization uses tick 0, where orientation
  does not matter. The factory initializes the pool in the same transaction that deploys the hook, so no
  deployed hook is ever observed uninitialized.
- SPEC.md section 3.1 still describes `quote` as an immutable of the hook; the section is preserved
  verbatim, and after the factory's single initialization the binding is final, which is the property the
  rules rely on. The `token == quote` constructor revert in that sentence is now enforced at initialization
  (a key containing the token twice cannot be sorted, and a key without the token is refused).

Tests (`test/SequencerHook.t.sol`, all six suites: native ETH, ERC20 quote as currency0 and as currency1,
each at tick 0 and at the launch FDV):

- `test_FreshHookOnlyFactoryAndExactPairCanInitialize`: a sorted pair without the token is refused; nothing
  is bound before the factory opens the pool; after it, `quote` and `quoteIs0` equal the opened key's, and a
  second initialization reverts `AlreadyInitialized`.
- `test_BindsTheQuoteTheFactoryOpensAndRejectsASecondPool` (replaces `test_RejectsPoolWithTheOtherQuoteKind`,
  whose premise was the constructor-given quote): unsorted keys are refused, a non-factory
  `PoolManager.initialize` reverts, the factory may open the token against either quote kind, and the
  binding then refuses any other pool.
- `test_ConstructorRejectsBadAddressesAndThresholds` updated to the new signature.
- `test/PulseTreasury.t.sol` and `script/DeploySepolia.s.sol` construct the hook with the new signature.

### 2. `src/PulseTreasury.sol`: a pulse that buys nothing reverts (`NoFill`)

Audit finding `dff8117` (low) reproduced on the unmodified tree (scratch test): with all liquidity
withdrawn, `pulse()` after 15 minutes returned `(0, 0)`, and the hook filed the swap as a 0-wei sell: heat
5 to 4, pressure 0 to -1000, `lastTs` reset so the next pulse waited another window. Fix: `unlockCallback`
reverts `NoFill()` when the swap delivered no IDM, so the state and the idle window are untouched.
Test: `test_PulseWithNoFillRevertsAndLeavesStateUntouched` (both packed words, heat, pressure, swapCount
and the treasury balance unchanged; the same pulse succeeds once liquidity is back).

### 3. `launch.json` renamed to `launch.reference.json`

Rule: the launch manifest is written by the manifest step after this work is accepted, and a `launch.json`
in the tree is checked as a manifest. Audit finding `4079cf18` (low) reproduces: the committed file had no
`pool.initialPrice`, carried non-schema keys (`pool.openingPrice`, `economics`) and a zero-address
constructor argument, so it would be rejected as a manifest. The requester's reference is kept under
`launch.reference.json`, updated to the new constructor arguments, `pool.initialPrice` and a `notes` text
that no longer points at a `contracts/` folder; it is documentation, not the manifest.

### 4. Documentation (audit finding `23d0a095`, info, reproduces)

- `README.md`: pulse idle 45 min corrected to 15 min (`PULSE_IDLE = 900 s`, as the code, the runbook and
  the tests say); token described as IDM, not SEQ; stale test count (127) replaced by the current 208 and
  the vector count (382) by the validator's 554; removed the `cd contracts` / `bin/` build instructions
  that do not apply to this tree; added an "IMD launch" section with the constructor the manifest writes,
  the callbacks, the fee (LP fee 12500 by policy, no hook fee) and what the launch deploys.
- `SPEC.md` section 9 opening sentence: 45 minutes corrected to 15 minutes. Section 3 is untouched.
- `IMD_LAUNCH_NOTES.md`: constructor signature and quote binding updated.
- `script/DeploySepolia.s.sol` comment: `contracts/launch.json` path corrected.

## Audit findings not acted on

- `65c8a7cc` (info): coverage statement, not a defect. Its checks were re-run on the adapted tree (every
  enabled callback manager-gated and returning its selector, factory-only single initialization at fee
  12500 / spacing 60, flags `0x3040`, no return delta, owner, payable, delegatecall, callcode, selfdestruct
  or liquidity callbacks).

## Launch rules checked against the delivered contracts

- Token: fixed supply 1e27 to `msg.sender` (the factory), 18 decimals, name "Intelligent Dance Market",
  symbol "IDM", no mint/owner/pause/blocklist/fee/upgrade; `test/SequencerToken.t.sol` covers supply and
  transfer. The brief asks nothing of the token the launch forbids.
- Hook: `beforeInitialize` and `afterInitialize` enabled and implemented, caller-checked, returning their
  selectors; `$poolManager` as a constructor argument, never a literal; `$token` and `$factory` as constructor
  arguments; no owner (`$owner` is not needed: the hook has no admin role); no hook fee, no return deltas,
  no fund handling, no ETH path; liquidity callbacks disabled so the factory's zero-liquidity fee collect
  passes untouched; LP fee 12500 required at initialization (the policy's tier), tick spacing 60.
- "Zero-fee" in the brief means the hook takes no fee; the pool's LP fee stays at the policy's 12500.
- Deployment, verification, addresses and receipts are IMD's deployer's step after acceptance; nothing was
  broadcast and no address was invented here.
