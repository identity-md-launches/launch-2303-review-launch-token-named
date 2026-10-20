# IDM adversarial tests

These additions exercise the accepted implementation without changing production code, configuration,
SPEC section 3, ABI, or the existing Solidity/vector tests. They require only the repository's vendored
dependencies and run offline.

| Suite | Properties and failure paths |
| --- | --- |
| `SequencerTokenAdversarial.t.sol` | Failed `transferFrom` rolls back finite allowances; approvals can be replaced/revoked; another spender cannot consume them; zero-address calls, maximum amounts, zero transfers and full-supply/self transfers; common administrative selectors and ETH payments are rejected. |
| `SequencerTokenInvariantTest` | Four holders exchange the real fixed supply through transfers and finite/infinite approvals. Every balance and all 16 allowances match an independent operation ledger; aggregate balances remain exactly `1e27`. Rejected spending is interleaved with successful operations. |
| `PulseTreasuryInvariant.t.sol` | Three keepers donate ETH/IDM, pulse, burn, forge callbacks and advance time, interleaved with real v4 trades, full liquidity removal/restoration and fee collection. Ghost totals reconcile treasury ETH with deposits minus actual spending, and IDM with deposits plus purchases minus burns. Caller balances cannot profit from pulse/burn. |
| Treasury/launch invariants | Total IDM across every participating holder remains `1e27`; the hook receives no trading revenue; only successful swaps advance `swapCount`; pool binding remains fixed; reserved bits/release count remain zero; reachable tempo, heat, pressure, root and size-EMA stay in SPEC bounds. |
| `IdmLaunchSafety.t.sol` | Token-only liquidity starts with zero ETH at the real PoolManager; first buy, sell, factory fee collection and full exit settle. Both initialization callbacks reject malformed keys without poisoning a subsequent valid initialization. Unauthorized/pre-initialization swaps, incorrect permission-address bits, and initialization at an address with no hook code fail. Actual deltas determine mutation independently of requested amounts/direction/hook data. A real swap writes only storage slots 0 and 1. Runtime checks reject common administrative selectors and escape opcodes. |
| Treasury transaction tests | Nested calls in one transaction check transient-guard cleanup after success, `NotIdle` on the next pulse, and rollback/recovery after `NoFill`. Pulse sizing is bounded and monotone across arbitrary `uint256` inputs. |

Each invariant campaign specifies 256 runs of depth 96 and `fail-on-revert = true` in Solidity.
Only the listed handler selectors are targeted. Expected failures assert their exact custom errors;
an unexpected revert fails the campaign. Stateless fuzz additions run 1,000 cases each. A deterministic
handler lifecycle exercises pulse success, early refusal, no-fill refusal, liquidity restoration,
burning and donations, so accounting checks also have an explicit non-vacuity witness.

The accounting identities come from the fixed-supply ERC-20 contract and treasury asset flows.
Hook bounds and the two-word write restriction come from SPEC section 3; treasury size/cadence and
permissionless pulse/burn behavior come from `PulseTreasury`'s interface. These properties do not use
`SequencerState.mutateV2` to manufacture expected transition outputs. Existing vector tests remain
responsible for the exact bit-for-bit transition oracle.

`helpers/IdmLaunchFixture.sol` is deliberately test-only. Its `launch()` creates the token and mined
hook, initializes the native-ETH/IDM pool at fee 12500 / spacing 60, and seeds liquidity within one
external call. Seeding occurs after the fixture has runtime code so PoolManager can call its unlock
callback. All settlements use assets owned by the fixture. The opening tick 193380 is the SPEC's
approximately 4 ETH FDV example, chosen to exercise a realistic one-sided pool; it is not a claim
about the actual launch's opening price.

Reproduce from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xf7cec6e43efa96394060a44d17ffa8baac215dce7381192a20d81bfdf9471bc2 forge test
python3 scripts/validate-vectors.py
```

For local checks with all generated artifacts kept in scratch, append
`--out test/scratch/out --cache-path test/scratch/cache` to the Forge commands.
No runtime RPC, environment mutation, downloaded dependency, or fork is required.

Local verification with the required seed: `forge build` succeeded; `forge test` reported 230 passed,
0 failed, 0 skipped across 15 suites. Foundry groups each suite's invariant predicates into one
campaign: the two campaigns executed 24,576 handler calls each, with zero unexpected reverts.
The independent vector validator passed all 130 v1 and 554 v2 cases. No new production defect was
reproduced by these checks.

## Launch verification limits

The imported tree contains `launch.reference.json`; it does not contain `launch.json`. Its adaptation
notes assign the final manifest and deployment to later launch stages. These tests use locally
deployed contracts and set chain ID 4663 for the launch fixtures. This does not verify Robinhood's
deployed PoolManager/factory, a final launch manifest, deployed hook/token/pool identifiers, or launch
receipts. A rehearsal against the final factory and live chain state, deployment verification and
receipts remain launch-stage work. No production address, transaction hash or receipt is invented.
