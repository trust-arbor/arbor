# Generic agent shell containment

The generic agent Shell API uses a mandatory operating-system policy on macOS.
An executable capability alone grants no filesystem access. Linux returns
`{:agent_containment_unavailable, :platform_not_qualified}` until an equivalent
filesystem/network policy has been implemented and qualified. There is no
fallback to the trusted host launcher.

The entry points are `authorize_and_execute/3`, its async and streaming variants,
and `Arbor.Actions.Shell.Execute` through the public Actions facade. They keep
the existing closed executable/argv grammar, startup executable pins, cleared
child environment, timeout/output limits, and owned process-group cleanup.
The anonymous prepared-command API now refuses with `:agent_authority_required`.
Its four-argument replacement is a source-owned adapter: Actions must
first consume its authenticated invocation proof; Orchestrator handlers must
first verify immutable RunAuthorization and forward its execution principal. It is not an external API or
a credential-bearing map that a model may construct.

## Filesystem authority

A call requires an explicit, existing, absolute, canonical `cwd`. A current
signed ordinary `arbor://fs/read/<absolute-directory>/**` capability must cover
that directory, and `touch` additionally requires the corresponding write grant.
The literal capability URI is `"arbor://fs/read" <> directory <> "/**"`.
The native scope is only the requested cwd subtree, intersecting the grant; it
never expands to the grant's larger parent. Current Security authorization and
the production Actions adapter's Trust policy both apply. Capabilities are read
again after the Trust check before launch.

This initial grammar rejects global roots, noncanonical aliases, arbitrary
wildcards, delegation, constrained/max-use grants, and task/session/principal
scope shapes instead of guessing how to project them into OS permissions.
These unsupported shapes can be added deliberately with matching qualification.
There is no caller-controlled `allowed_paths`, environment, profile, network,
or launcher override. Existing programmatic authorizers must implement the
filesystem callback; a command-only callback fails closed.

The native Seatbelt profile denies by default. It permits only the pinned
utility, immutable system libraries and dyld bootstrap inputs, the authorized
workdir, and minimal null/random devices. Root-directory read access is needed
by Apple's dyld `openat` bootstrap; this exposes root directory entries, not
arbitrary host file content. Network operations (including local sockets),
process creation, execution of another binary, arbitrary Mach access, and
outside-workdir writes remain denied. The approved write mode is currently
reachable only through `touch` in the generic argv grammar.

Explicit deny rules protect common credential/authority paths even if a grant
covers them: `.ssh`, `.aws`, `.azure`, `.gnupg`, `.claude`, `.codex`, `.agents`,
`.config`, `.arbor`, `.git`,
`.kube`, `.docker`, `.netrc`, `.npmrc`, `.pypirc`, `.env` variants, credential and
secret filenames, SSH private-key filenames, and macOS Keychains/Application
Support directories. This is not a content classifier: secrets intentionally
copied or prelinked into ordinary granted input files are not automatically
identified. Do not grant a directory containing unrestricted confidential input.

## Trust boundary and limits

Arbor's BEAM, native launcher, executable policy, Security/Trust configuration,
and the host OS remain trusted. `execute/2` and `execute_direct/3` are explicitly
trusted host APIs; plugins with arbitrary in-BEAM code can invoke those APIs or
raw OS calls. This packet does not turn the BEAM into a plugin sandbox or cover
all specialized Actions. The contained Mix validation path is unchanged.

A running child's kernel policy is fixed at admission. Revocation denies later
invocations; it does not promise immediate termination of an already-running
child. Existing deadline/output/group ownership controls remain in force.
macOS has no `fexecve`; the existing checked path handoff and its trusted-host
assumption remain. This adds no UID isolation, memory quota, CPU quota, or file
size quota. It does not claim comprehensive resource-exhaustion protection.

Apple marks the sandbox API as deprecated in the installed SDK's `sandbox.h`.
The profile relies on currently available Seatbelt operations and is qualified
on the tested OS, not promised for every future macOS release. Missing launcher,
profile, or platform support must fail closed. Apple's installed
`/System/Library/Sandbox/Profiles/dyld-support.sb` documents the Cryptex dyld
bootstrap and root-directory read requirement; this implementation copies only
needed fixed permissions and does not import the broader system profile.

## Qualification

`Arbor.Shell.agent_execution_identity/0` returns a JSON-clean identity snapshot:
policy version, OS/support state, SHA-256 of the opened native launcher, and MD5
identities of loaded enforcement modules plus the configured authorizer. It
fails closed if that observation is unavailable or changes while sampled. This
is a qualification input, not a promise that a trusted host cannot replace a
file after the snapshot. Qualification records separately bind the committed
native probe and runner sources; release runtime code does not read test files.

Public regression selectors, one owning app per isolated BEAM:

- Shell: `test/arbor/shell/agent_filesystem_containment_security_regression_test.exs`
- Actions: `test/arbor/actions/shell_filesystem_containment_security_regression_test.exs`

The committed native fixture at `apps/arbor_shell/test/fixtures/agent_containment`
uses the production `agent-read`/`agent-write` modes with a synthetic C probe.
It tests kernel enforcement independently of the narrower agent executable
allowlist, plus real `cat` and `touch` effects. It never becomes an allowed
agent executable. The Python runner takes the exact compiled launcher and probe
paths, creates/deletes only its own random temporary tree, records binary
hashes and terminal outcomes, and opens no remote connection. Network negatives
attempt only disposable local binds.

Public parent/fix results and platform-specific source/binary hashes belong in
the qualification evidence; compilation or a source review alone is not proof
that the OS policy executed. A missing Security fixture, startup abort, or
unavailable outer test sandbox cannot count as an intended negative result.
