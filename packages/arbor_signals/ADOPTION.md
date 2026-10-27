# Signals adoption into the monorepo

Decision recorded for the 2026-10-27 adoption from Arbor Main
`27c4eea802ec65969ac963701914ce1a28b000c7`.

## Source and ownership

All 27 current Signals production files move from
`apps/arbor_kernel_runtime/lib/arbor/signals.ex` and `signals/` into this
package. The frozen sibling repository supplied a boundary map, not source to
run or restore. Its older implementation and qualification archives are not
copied. The embedded Signals definitions are removed in the same adoption.
[`adoption-source-map.json`](adoption-source-map.json) records each original
Git blob, destination hash and adaptation, including package-owned helpers.

The package owns its identifiers, passive API/taint/context contracts, and a
renamed copy of Main's authenticated-call helper. Copying that helper avoids a
dependency back into active Kernel Runtime while preserving the caller-owned
ETS proof, challenge expiry, custody checks and wire protocol. Common retains
its own helper under its original module name. Future protocol changes need an
explicit compatibility review; these are separate modules, not competing
owners of the Signals facade.

## Host composition

Arbor declares Signals as a `runtime: false` path dependency. Kernel Runtime
also declares `included_applications: [:arbor_signals]`, retaining application
metadata and release closure without eagerly starting a second application.
Kernel Runtime continues to start `Arbor.Signals.Application` inside its own
full-profile supervisor, after boot-profile admission and ProviderGate. Its
activation-only path must start no Signals processes and must not load the
`Arbor.Signals.Application` module.

Supervised-call provenance still checks the exact registered descendant. Arbor
configures `supervision_root: {:application, :arbor_kernel_runtime}` and
`supervision_path: [Arbor.Signals.Application]`. Standalone defaults instead
use the Signals application root and an empty path. Registered-name occupancy
alone never establishes ownership.

Configuration moves from `config :arbor_kernel, signals: [...]` to flat
`config :arbor_signals, ...`. There is no old-owner fallback and therefore no
second configuration authority. Test-fixture compilation is likewise owned by
`:arbor_signals`.

## Contract compatibility

The host adapter `Arbor.KernelRuntime.Adapters.SignalAuthContext` recognizes
only the original host context. The package treats credentials as opaque terms
through `Contracts.AuthorizationContext`; it does not accept an ordinary map
merely because it contains principal or proof fields. The security provider
still verifies the signed request and authorizes the exact resource.

Arbor supplies its original `Arbor.Contracts.Security.Taint` and
`TaintEnvelope` modules through the taint-provider ports. Host results retain
their original struct identities, legacy Erlang-term hashes and canonical
durable-envelope representation. Standalone consumers use package-owned
contracts. Foreign structs are not generically coerced; renamed standalone
structs must not be treated as identical legacy hash inputs.

## Validation record

Completed focused checks:

| Check | Result |
| --- | --- |
| Standalone Signals suite | 481 tests, zero failures; five distributed tests excluded |
| Separate package distributed suite | Five tests, zero failures, using an owned foreground EPMD |
| Host runtime, boot admission and Signals integration | 71 tests, zero failures |
| Commands tooling and source inventories | 163 tests, zero failures; one opt-in release probe skipped |
| Kernel hierarchy and source guards | 21 tests, zero failures |
| Security signal synchronization regressions | Five tests, zero failures |

The independent cold consumer's locked production dependency resolution,
strict compilation, delivery canary, production release and no-Mix release
evaluation passed. The initial offline attempt stopped before compilation
because a public Hex registry entry was not cached; that attempt remains in
the evidence ledger.

Umbrella strict compilation also passed. The final host groups ran against
the standard `_build/test` layout, after removal of two unused retained host
test helpers. Earlier host fixture-expectation failures and their corrected
reruns remain recorded in the retained evidence.

Final strict package/umbrella compilation and the standalone suite were rerun
after fixing 17 introduced alias usage/order findings. Runtime integration
again passed 71 tests. Changed fixture consumers passed: Security 67, Memory
15 (explicit database lane), Dashboard eight, Agent 14, and Orchestrator one
through its self-bootstrapping no-start launcher. The final cold consumer and
production release were rebuilt from fresh source and passed all five steps.

The full umbrella fast attempt was capped at 45 minutes 21 seconds while in
Actions and is incomplete. It reported a Kernel atom-count assertion failure,
11 Shell global process-absence failures, one AI authorizer-fixture failure,
and an Actions state-query timeout. The Shell process belongs to another
worktree and was left untouched. Loading Shell's helper first reproduces the
same AI failure on the parent. Kernel and Actions pass their isolated parent
controls; their aggregate failures remain unresolved. These results do not
qualify the full umbrella gate.

`quality` remains red: unchanged Dashboard formatting, existing/moved lint
patterns, 24 unused lock entries, xref 104 against cap 88, coupling debt,
stale Platform classifications and an unavailable recovery overlay. Xref is
also 104 on the parent; undeclared coupling decreases from 5,191 to 5,183,
with upward edges unchanged at 60. The final scoped Credo check retains 155
existing or equivalent moved findings. No baseline was refreshed. App-env
inventory passes with zero legacy-owner writes. Profile/closure evidence
checks pass while their architecture status remains blocked.

[`qualification.json`](qualification.json) records the passing checks,
failed attempts and acceptance limits. Private logs, command provenance and
exact final-commit binding remain in `tmp/verification/`.

The product's proposed M2 per-profile release gate is not implemented. The
standalone release check does not claim to qualify that product gate. The
final task verification ledger must bind these results to the committed
adoption and record any remaining baseline limitations.

## Rollback

Rollback is one revert of the complete adoption commit, followed by a fresh
build and the same boot/security canary. Reintroducing embedded definitions
while retaining the package would create duplicate owners. The local rehearsal
used immutable candidate
`bd1c2dfef44ceb7fb65c8f284f53634d55ed8fe6`. Its revert restored the exact
parent tree `06823568cff7d1096b48fb2e150eb608b350703a`; all 5,320 tracked
files matched the restored index before and after checks. After removing only
first-party build artifacts, strict compilation passed, followed by 43
original KernelRuntime/Signals canaries and five Security synchronization
regressions, all with zero failures. The final task ledger binds the normal
adoption commit to this source-identical snapshot and its own exact revert
check. Private raw evidence remains under `tmp/verification/rollback/`.
