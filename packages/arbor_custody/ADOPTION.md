# Custody support adoption

This is the first shared-support prerequisite for Capabilities extraction. The
implementations come from authoritative Main commit
`7e3860de5fd2d62317f09da1636ded70e7e0ddbe`, including its current security
repairs. Frozen sibling libraries supply no implementation in this change.
`adoption-source-map.json` records the source blobs and adapted destination
digests.

## Ownership and compatibility

`Arbor.Custody` owns the authenticated-call exchange, process-private state and
generic supervision-provenance helpers. It depends only on OTP, with `:crypto`
as an additional application. Starting the package creates no custody owner,
broker, registry or store. The consumer owns those processes and resources.

The three Common implementations are replaced by forwarding compatibility
modules. Both the existing Common facade and new Custody facade operate
synchronously in the calling process. Fixed legacy identity atoms preserve the
existing process-dictionary seals, ETS table names and authenticated-call exit
origins. The wire protocol, challenge limits, schemas, anchors and validation
algorithms are unchanged. This preserves already-created custody; it does not
promise an automatic application upgrade or replace the consumer's restart
procedure.

Host projects declare Custody as a versioned local package dependency. This
also keeps its implicit external Boundary classification stable across
incremental compiles; the installed Boundary compiler loses that classification
when treating an unversioned path dependency as a local boundary project.
Validation includes repeated ordinary compiles after rebuilding the dependency.

Security uses the new facade for startup-root provenance. Its richer
`SupervisedOwner` policy stays in Security: exact child paths, protected table
ownership and the distinction between an absent child and a configured child
that is down remain essential. `Security.PrivateState` has a different handle
and anchor contract and is also retained unchanged.

## Deliberate scope

Signals keeps its separate authenticated-call implementation and seal identity.
Adopting Custody there also requires changing dependency levels and qualifying
the standalone Signals consumer again. No Signals dependency or lifecycle
changes are included here.

SigningAuthority, taint contracts and OIDC remain separate prerequisites. This
package supplies reusable custody primitives; it grants no signing authority,
implements no trust policy and does not complete Capabilities extraction.

## Validation boundary

Package tests exercise the public facade without Kernel Runtime or Security.
Host compatibility tests cover the Common forwarding APIs and existing sealed
resources. Existing Common and Security regressions remain in their owning
applications. The standalone consumer additionally checks the packaged
production release and its application closure.
Fresh and incremental compilation are both checked
[AL:prove-app-boundaries-by-running-from-the-child-project-with-a-fresh-build!].

The adoption map is historical provenance for this extraction. Future repairs
belong in the package implementation and its tests; the old implementations
must not be restored in Kernel Runtime.
