# K5 capability enforcement matrix

**Date:** 2026-10-16
**Status:** audit declaration, not an authorization path

`Arbor.Trust.CapabilityEnforcementMatrix` records the intended soft gate and
independent hard gate for each high-risk capability profile. It is a read-only
table. `Arbor.Trust.capability_enforcement_rows/0` and
`capability_enforcement_for/1` return declarations. They do not authorize,
mint, revoke, or escalate.

## Why this is not enforced at `authorize/4`

The matrix exists to keep the **hard** gate off the same decision path as the
**soft** gate. Every declared hard gate sets `authorize4_dependent?: false`.
The point of K5 defense-in-depth is that an authorization bug must not also
remove the host, filesystem, network, admin, or budget boundary.

Wiring the matrix into `Arbor.Security.authorize/4` (or making
`authorize/4` look up a row and "enforce" `hard_gate`) would couple the hard
gate to the soft path the table says must stay independent. That is the
opposite of the invariant already tested in
`apps/arbor_trust/test/arbor/trust/capability_enforcement_matrix_test.exs`.

The hard gates are also not a single lookup. They are owned by different
apps and mechanisms:

| Class | Soft gate | Hard gate owner | Hard mechanism |
| --- | --- | --- | --- |
| `shell_exec` / `process_spawn` | trust `:ask` ceiling | `arbor_sandbox` | sandboxed execution, no NIC unless projected |
| `network_egress` | `EgressGate` | `arbor_sandbox` | host route or netns filter |
| `filesystem_write` / `local_write` | `FileGuard` / trust `:ask` | `arbor_sandbox` | worktree or mount confinement |
| `administrative_mutation` | capability authorize | `arbor_security` | non-agent admin boundary |
| `financial` | capability authorize | `arbor_security` | non-agent budget or payment boundary |

Those hard mechanisms are (or must be) implemented at their owner boundary.
A matrix row is not a substitute for that code.

## What would be needed to enforce it

Do not add a matrix lookup to `authorize/4`. Enforcement means each
`hard_gate.decision_path` becomes a real, independently tested check in its
owner app:

1. `host_execution_containment` — sandbox refuses unsandboxed shell/process
   spawn even when trust/capability would allow it.
2. `host_network_boundary` — host route or netns filter projected from the
   egress capability, independent of `EgressGate`.
3. `host_filesystem_boundary` — worktree/mount confinement for write paths,
   independent of `FileGuard`.
4. `operator_admin_boundary` — privileged identity/governance/trust writes
   require a non-agent administrative principal.
5. `operator_budget_boundary` — metered or financial effects require a
   non-agent budget or payment check.

After those exist, add a packaging or CI audit that every matrix row's
`hard_gate.id` maps to a live check on a different code path than
`Arbor.Security.authorize/4`. Until then the table is the audit surface for
that work, not a runtime gate.
