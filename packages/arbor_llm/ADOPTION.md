# LLM adoption boundary

Arbor Main at `8a4d20ffe3c43da16fd0760b3fd60878b9be10cc` is the mechanism and
test source of truth. Frozen sibling code is only seam and disposition reference.
The source/test disposition ledger records the physical moves and any bounded
composition changes separately from the preserved source facts.

## Application-scoped namespace membership

The package contains `Arbor.LLM.*`, plus the existing pure
`Arbor.AI.LLMError` and `Arbor.Orchestrator.ToolHooks` modules. Those historical
names remain unchanged. LLMError calls the LLM facade, and the LLM mechanisms
call LLMError; they belong to one application boundary rather than reciprocal
independent Boundary roots.

Boundary 0.11.0 documents name-prefix membership in `lib/boundary.ex:83-96` and
explicitly restricts `classify_to` to Mix tasks and protocol implementations at
`:155-156`. `lib/boundary/definition.ex:80-85` enforces that restriction.
`lib/boundary/checker.ex:150-165` includes every declared dependency when checking
cycles. No manual classification exception or disabled check is used here.

The metadata-only `Arbor` module defines the common namespace boundary. Its
exports are exactly the preserved `LLM` subtree and the two historical helper
modules. It exposes no functions, process or application callback. `Arbor.LLM`
remains the sole public LLM facade. Strict Boundary consumers name `Arbor` as
the package boundary dependency; application provenance remains `:arbor_llm`.
No consumer calls a second facade.

External declarations name actual implicit boundaries: `Mint.TransportError`
and the separately owned `Plug.Cowboy`, alongside `Plug`. The pinned Boundary
implementation does not check pure Erlang applications, so Ranch and Telemetry
remain ordinary declared Mix dependencies and behavioral test subjects rather
than invalid Boundary names. Strict compilation verifies this distinction
[AL:prove-app-boundaries-by-running-from-the-child-project-with-a-fresh-build].

Crucially, namespace matching is application-scoped. In the pinned
`Boundary.Mix.Classifier.classify/4` (`lib/boundary/mix/classifier.ex:33-57`),
`modules` is the supplied current application's module inventory; only that
inventory is traversed to add module membership. `Boundary.Mix.View` loads and
classifies each dependency application's inventory separately. A matching
`Arbor.*` prefix does not confer ownership over Kernel, Support, AI, Orchestrator
or any other application's modules. The owning structural test invokes that
actual classifier with the compiled LLM inventory and checks that real Kernel
and Support modules remain outside it. The existing `Enumerable` and `Inspect`
protocol implementations retain their protocol namespaces; Boundary's documented
protocol exception leaves them unclassified. The structural test accounts for
those genuine implementations separately, without disabling checks on ordinary
modules or changing protocol behavior.

Pinned source hashes for the inspected Boundary 0.11.0 implementation:

- `lib/boundary.ex`: `18b7fbef4fa7d69e1c70f3852147134933bdb05900adabf0efe7657880f16cc9`
- `lib/boundary/definition.ex`: `ac523d3411b5689f0e303aa2a25864bd4fe27c267549253d1e6ef51b57daf30e`
- `lib/boundary/mix/classifier.ex`: `d91bbb54f9769bed1c32d94326e7e00efa543dab76906d599b34eec30f6df2a5`
- `lib/boundary/checker.ex`: `6ee38765ae0801dfaf857d44b0001a46579588b8d06d7bf3f817a2ed0f20ab82`

## Runtime and package contract

The canonical active application remains `:arbor_llm`, with the original
`Arbor.LLM.Application`, supervisor and OAuth child identities. Its production
first-party dependencies are Kernel, Support and OAuth. Signals is declared
with `runtime: false` for the existing taint helpers; it is not started by LLM.
There is no Kernel Runtime, product Host, AI, Orchestrator or authority dependency.
Product collaborators are selected explicitly by the host through LLM ports.
ToolLoop's default executor and default catalog come from the trusted
`:tool_executor` setting; the product selects the preserved
`Arbor.LLM.ArborActionsExecutor`. Standalone callers can supply both `:tools`
and `:tool_executor` explicitly. Missing executors or default catalogs return a
typed error before a provider call.

All first-party dependencies have public version requirements. Optional local
source overrides are build inputs only, named `ARBOR_KERNEL_PATH`,
`ARBOR_SUPPORT_PATH`, `ARBOR_OAUTH_PATH` and `ARBOR_SIGNALS_PATH`; dependency
helpers do not propagate `Mix.env()`. The owning lock uses unchanged public
records from the current Root lock. Package metadata excludes tests, config,
examples, adoption evidence and build outputs from the published payload.

The Boundary declaration preserves the existing public mechanism module surface.
Its external dependencies name the actual public Kernel/Support/OAuth/Signals
roots and directly used HTTP/serialization/observation libraries. Runtime atoms,
callbacks and supervision protocols remain dependencies even when no static
Elixir alias is present. No dynamic product module fallback is added by this
namespace choice.

Qualification receipts, rather than this source document, establish strict
compilation, test, independent consumer, source-hidden runtime and rollback
results for a particular reviewed revision. Publication remains separately
authorized.

## Source and test preservation

[The portable source map](adoption-source-map.json) binds the original 186 LLM
files to their current package or product owners at the base revision above.
It records original Git blobs and source hashes separately from current target
hashes, and maps every original case label and source-chunk hash: 974 cases stay
with the package and 35 move to their actual product composition owners. The
four incoming helper files and their eight cases, plus eight lower prerequisite
files and their 87 cases, remain separate inventories. Added cases do not replace
any of those originals.

Initial mechanical moves were literal. Subsequent reviewed port/configuration
and test-fixture edits have distinct target hashes. The 136-file formatting
receipt, seven-file pass and later 11-file fixture pass prove metadata-stripped
AST equality for their respective before/after inputs. A later one-file Root formatter
correction also preserves metadata-stripped AST equality. The 147 explicit raw-chunk
differences remain labeled as the earlier pre-format stage; they do not claim
final raw identity.

At the recorded 47 owning-case fixture-correction stage, finite policies and
caller-owned setup repairs left assertions, case names, tags and timing budgets
unchanged. Those stage-specific proofs and formatted target hashes remain
bound by the map; the separate later Subject exception is described below.
Historical tooling receipts record 11 LLM and 13 Support stdlib
cases, followed by a separately preserved 14-LLM/79-Trust tooling snapshot.
The current scoped dotenv guard has 24 LLM stdlib cases, including 10 temporary
context cases that leave unused Home dotenv inputs unqueried while retaining
consumed-directory dotenv and Home VM-startup refusals. The byte-identical Trust
helper retains its prior 79-case receipt without a rerun. These tooling receipts
do not qualify a cold VM. The map is a static source/disposition ledger,
excluded from the Hex payload. Run-specific
qualification receipts establish owning behavior and distribution results.

A later readability pass adds scoped aliases and replaces one single-clause
fixture `with` with an equivalent `case`. Source records preserve the previous
target pins; a separate 18-file Root formatting receipt establishes AST equality
only between the edited and formatted sources. Earlier owning, API and
compilation receipts remain tied to their recorded revisions.

The user-authorized Subject deadline/cancellation reliability exception changes
one preserved owning case and its test adapter/cleanup. It replaces only the
fragile host wall-time assertion `elapsed < 175` with actual provider-lifecycle
oracles: the announced provider execution PID blocks until a test-owned release,
its monitored termination must precede that release and teardown, and the public
Subject runner must exit normally. The product `timeout: 50`, exact
`{:error, {:request_deadline_exceeded, 50}}`, `elapsed >= 40`, and
`refute_receive :late_complete_side_effect, 250` remain. The 1000ms harness waits
bound observation and cleanup; they do not increase the product deadline.

All 29 Subject case identities/order/tags remain, and the other 28 case chunks
are byte-identical to the prior target. The map retains that `5a8df1ab...` target
and all historical source facts separately from this deliberate assertion and
fixture change. Earlier setup-only assertion/budget-preservation and formatting
proofs remain historical; they do not assert that all original assertions or
timing assertions are byte-identical in the current target. The map binds actual
Root formatting and AST evidence (29 named tests, 74 assert-family and three
refute-family forms), the passing whole Subject file, and two negative controls
that fail at the intended deadline/cancellation assertions. The full owning run
remains failed with two other test-fixture issues under investigation. These
scoped receipts supply no full-suite or cold qualification credit.

A later source-guard correction retains ToolLoop's two forbidden dependency
checks and dynamic emit check, while replacing a stale qualified-call spelling
with the actual `Arbor.LLM.Config` alias and `Config.signal_module()` assignment.
That single guard case now has five leading assert/refute macros versus four
historically; the map preserves the old counts and pins this explicit addition.

A separate tool-result fixture stage selects an existing fixed prompt-sanitizer
nonce in its shared run helper. All three case blocks, fourteen assertions and
two tags remain unchanged from the prior target, as do the finite policy routes
and production mechanisms. The failed historical random nonce was not recorded;
this source-bound correction makes no claim that its historical cause was proved.
A later fresh run passed strict compilation, the one-case controlled nonce
diagnostic, all 44 focused tests, and the full 1,032-test suite (one local-provider
case excluded). The map binds that exact source revision and clean preservation
and cleanup results. Earlier failed attempts remain failed. Normal hook
formatting is recorded separately; these results supply no cold release credit.
