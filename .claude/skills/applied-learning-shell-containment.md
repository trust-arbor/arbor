# Applied Learning: Shell and Containment

Read this when executing commands, configuring process or container containment, or validating executable identity and resource bounds.

## Retained Applied Learning

<!-- applied-learning: admission-ceilings-must-be-supported-by-every-lower-execution-layer -->
<a id="applied-learning-admission-ceilings-must-be-supported-by-every-lower-execution-layer"></a>
**Admission ceilings must be supported by every lower execution layer.** Shell admitted
an intensive Apple Container operation at 1,200,000 ms, but `PortSession` still applied
its generic 600,000 ms stream ceiling and the unit worker redacted the launch rejection
as `:list_containment_failure`. Keep the generic public ceiling closed; add a narrow
profile-keyed internal path for an already-admitted durable plan, and test generic,
standard, intensive, unknown-profile, and worker-forwarding behavior end to end (found
2026-07-17 validating the binding council substrate).

<!-- applied-learning: one-shot-stdin-needs-an-explicit-eof-and-tests-must-assert-termination -->
<a id="applied-learning-one-shot-stdin-needs-an-explicit-eof-and-tests-must-assert-termination"></a>
**One-shot stdin needs an explicit EOF, and tests must assert termination.**
Writing bytes to a child pipe without closing the writer lets programs such as
`cat` and `git hash-object --stdin` produce output and then wait forever. A test
that asserts only captured output can therefore pass while every real call
times out. One-shot execution must close stdin after its optional payload;
interactive sessions must keep a separate open-input protocol, and regressions
must assert normal terminal status as well as exact bytes (found 2026-07-13 in
`Arbor.Shell.ProcessGroup`).

<!-- applied-learning: a-declared-workflow-profile-is-not-executable-until-every-claimed-invariant-is-mechanically-enforced -->
<a id="applied-learning-a-declared-workflow-profile-is-not-executable-until-every-claimed-invariant-is-mechanically-enforced"></a>
**A declared workflow profile is not executable until every claimed invariant is mechanically enforced.** Running a selected `_test.exs` file against the candidate does not prove a security regression fails against the base revision and passes against the candidate. Keep the profile discoverable but fail closed with a precise missing-primitive reason until both sides of the claim are enforced (found 2026-07-10 reviewing the initial `security_regression` compiler profile).

<!-- applied-learning: basic-shell-sandbox-checks-the-command-string-even-after-argument-escaping -->
<a id="applied-learning-basic-shell-sandbox-checks-the-command-string-even-after-argument-escaping"></a>
**Basic-shell sandbox checks the command string even after argument escaping.** `ShellEscape` single-quotes dangerous commit-message text correctly, but `Arbor.Shell.Sandbox` still rejects metacharacters like backticks inside the assembled command string. Git actions that run via `Shell.execute(..., sandbox: :basic)` need to normalize user/task-derived arguments such as commit messages before constructing the shell command, or use a non-shell argv execution path.

<!-- applied-learning: schema-bounded-mix-actions-must-stay-within-the-basic-shell-sandbox-s-allowed-flag-set -->
<a id="applied-learning-schema-bounded-mix-actions-must-stay-within-the-basic-shell-sandbox-s-allowed-flag-set"></a>
**Schema-bounded Mix actions must stay within the basic shell sandbox's allowed flag set.** `Mix.Compile` cannot expose `--force` while it runs through `Shell.execute(..., sandbox: :basic)`: the sandbox rejects that flag before Mix starts. Add flags only after checking the sandbox policy or moving the action to a non-shell argv execution path (found 2026-07-09 while routing coding-agent validation through `arbor://action/mix/compile`).

<!-- applied-learning: arbor-shell-list-executions-0-returns-ok-executions-not-a-bare-list -->
<a id="applied-learning-arbor-shell-list-executions-0-returns-ok-executions-not-a-bare-list"></a>
**`Arbor.Shell.list_executions/0` returns `{:ok, executions}`, not a bare list.** Pattern-match the facade result before applying `length/1`, `MapSet`, or list transforms in live diagnostics; otherwise the diagnostic itself fails before the behavior under test runs (found 2026-07-15 during the spawn-capable facade registry proof).

<!-- applied-learning: reply-first-genserver-cleanup-still-has-to-resolve-every-supported-server-reference -->
<a id="applied-learning-reply-first-genserver-cleanup-still-has-to-resolve-every-supported-server-reference"></a>
**Reply-first GenServer cleanup still has to resolve every supported server reference.** Direct
`send/2` and `Process.monitor/1` work for PIDs but regress registered atom or `{:via, ...}` servers,
and a queued caller can die before the server accepts its request. Resolve through
`GenServer.whereis/1`, monitor the resolved PID, and cancel queued pre-accept work as well as active
work (found 2026-07-12 in ACP recovery fencing).

<!-- applied-learning: protocol-cancellation-must-finish-before-eager-transport-teardown -->
<a id="applied-learning-protocol-cancellation-must-finish-before-eager-transport-teardown"></a>
**Protocol cancellation must finish before eager transport teardown.** Starting an asynchronous
ACP cancel callback and immediately disconnecting races the callback against a dead client. For
caller/owner cancellation that terminates the session, run cancel through a bounded owned operation
before disconnect; keep hard/inactivity recovery reply-first when the session must remain resumable.

<!-- applied-learning: quote-shell-search-patterns-so-documentation-backticks-stay-literal -->
<a id="applied-learning-quote-shell-search-patterns-so-documentation-backticks-stay-literal"></a>
**Quote shell search patterns so documentation backticks stay literal.** Backticks inside a double-quoted `zsh -c` command are command substitutions, even when they appear only in an `rg` pattern. Use a single-quoted shell pattern (or otherwise escape the backticks) when searching Markdown; otherwise a harmless source search can unexpectedly execute the documented command (found 2026-07-10 while searching for the Mix-wrapper learning).

<!-- applied-learning: a-signed-capability-manifest-must-bind-the-exact-executable-artifact-and-inputs -->
<a id="applied-learning-a-signed-capability-manifest-must-bind-the-exact-executable-artifact-and-inputs"></a>
**A signed capability manifest must bind the exact executable artifact and inputs.** Signing only a list of allowed capabilities lets the same valid manifest be copied beside different DOT or reused with a different workdir/argument payload. Scheduled/custom graph attestations must cover canonical graph bytes/hash, pipeline identity, fixed workdir, and the reviewed argument contract, then recheck the hash immediately before execution (found 2026-07-10 auditing the scheduler DOT-authorship redesign).

<!-- applied-learning: safepath-resolve-within-2-is-lexical-containment-not-an-existing-file-authorization-result -->
<a id="applied-learning-safepath-resolve-within-2-is-lexical-containment-not-an-existing-file-authorization-result"></a>
**`SafePath.resolve_within/2` is lexical containment, not an existing-file authorization result.** It normalizes `..` but does not return a symlink-resolved target. Before reading a user-selected existing file, resolve and compare the real workdir and real target, authorize the caller-visible path through the fs/FileGuard gate, and read the proven canonical target; otherwise an in-workdir symlink can redirect a read outside the workspace (found 2026-07-10 reviewing Grok's pipeline `source_file` authorization fix).

<!-- applied-learning: a-bound-nested-graph-is-immutable-executable-input -->
<a id="applied-learning-a-bound-nested-graph-is-immutable-executable-input"></a>
**A bound nested graph is immutable executable input.** Do not rewrite node attributes such as question, mode, or quorum after the parent manifest has attested the child graph; even semantically equivalent mutation changes the compiled object and correctly fails binding verification. Put per-run data in the child's initial context, reject executable overrides on bound paths, and preserve custom graph mutation only for explicitly unbound execution (found 2026-07-10 while dogfooding the bound coding-review council).

<!-- applied-learning: authority-key-scanners-must-distinguish-executable-control-data-from-declarative-schemas -->
<a id="applied-learning-authority-key-scanners-must-distinguish-executable-control-data-from-declarative-schemas"></a>
**Authority-key scanners must distinguish executable control data from declarative schemas.** Recursively flagging every key named `agent_id` or `owner` across a compiler artifact rejects legitimate action JSON Schema properties even though those names never become runtime values. Scan the plan/compiler control envelope, and validate trusted descriptor or execution-manifest subtrees with their exact structural/catalog validators instead of applying control-key heuristics to schema vocabulary (found 2026-07-10 when the live CodingPlan catalog included `council_review_change.agent_id` and `git_pr.owner`).

<!-- applied-learning: module-atoms-are-executable-selectors-not-inert-descriptor-data -->
<a id="applied-learning-module-atoms-are-executable-selectors-not-inert-descriptor-data"></a>
**Module atoms are executable selectors, not inert descriptor data.** Moving an MFA out of a per-task record is incomplete if that record still chooses backend or audit modules that trusted cleanup code later invokes. Pin every executable module at the owner process's trusted initialization boundary; normalize per-task lifecycle descriptors to scalar provenance such as caller and trace IDs before storing them (found 2026-07-11 in the second terminal-approval cleanup council review).

<!-- applied-learning: acceptance-must-be-derived-from-evidence-never-trusted-from-a-report-summary -->
<a id="applied-learning-acceptance-must-be-derived-from-evidence-never-trusted-from-a-report-summary"></a>
**Acceptance must be derived from evidence, never trusted from a report summary.** A deterministic benchmark can execute nothing yet pass if `acceptance/1` reads only caller-supplied aggregate counts. Validate a closed, non-empty row/pair schema, recompute every aggregate from status-specific objective/lifecycle/artifact checks, and reject summaries that do not exactly match the derived result (found 2026-07-11 reviewing the coding conformance benchmark).

<!-- applied-learning: verify-static-runtime-api-claims-against-the-pinned-toolchain-when-executable-evidence-disagrees -->
<a id="applied-learning-verify-static-runtime-api-claims-against-the-pinned-toolchain-when-executable-evidence-disagrees"></a>
**Verify static runtime API claims against the pinned toolchain when executable evidence disagrees.** Documentation or memory about an Erlang option can be stale across OTP releases; if a public behavioral test succeeds on the repository's pinned runtime, reproduce the disputed call directly there before redesigning around an assumed incompatibility. Treat the observed pinned behavior as evidence while still checking portability deliberately (found 2026-07-11 reviewing `:file.open` mode handling in eval persistence).

<!-- applied-learning: a-command-name-policy-cannot-enforce-an-argument-sensitive-shell-safety-floor -->
<a id="applied-learning-a-command-name-policy-cannot-enforce-an-argument-sensitive-shell-safety-floor"></a>
**A command-name policy cannot enforce an argument-sensitive shell safety floor.** The pinned Bash `CommandPolicy` callback receives only command name and category, so it cannot see opaque payloads such as `sh -c`, `find -exec`, or `awk system(...)`, nor Arbor's dangerous flags. Do not claim capability-safe compound execution from that callback alone: add an argv-aware runtime gate or reject interpreter/wrapper and dynamically constructed forms fail closed, and keep the feature disabled while that boundary is incomplete (found 2026-07-11 reviewing CapShell resource-bound dogfood).

<!-- applied-learning: disable-the-authority-mismatch-not-only-one-compound-shell-implementation -->
<a id="applied-learning-disable-the-authority-mismatch-not-only-one-compound-shell-implementation"></a>
**Disable the authority mismatch, not only one compound-shell implementation.** Stubbing CapShell still leaves a bypass if `ExecuteScript`, async/streaming authorization, a DOT shell handler, or `sandbox: :none` authorizes only the leading token and then executes the whole compound string. Agent-facing shell boundaries must reject compound input before authorization, approval creation, temporary files, sessions, or processes until runtime-expanded argv and process ownership can be proven; reserve unchecked compound execution for explicit trusted-system APIs (found 2026-07-11 reviewing the CapShell fail-closed correction).

<!-- applied-learning: killing-a-port-owner-does-not-prove-its-descendants-stopped -->
<a id="applied-learning-killing-a-port-owner-does-not-prove-its-descendants-stopped"></a>
**Killing a Port owner does not prove its descendants stopped.** Timeout, cancellation, or output-limit code that sends SIGKILL only to the immediate OS PID can return while Git hooks, Mix children, helpers, or detached subprocesses continue side effects. Launch untrusted external work in an owned process group/container, terminate the whole group on every terminal path, await verified group exhaustion, and regress with delayed descendant markers (found 2026-07-11 reviewing the direct-argv shell correction).

<!-- applied-learning: a-port-env-option-is-an-override-list-not-an-empty-environment -->
<a id="applied-learning-a-port-env-option-is-an-override-list-not-an-empty-environment"></a>
**A Port `:env` option is an override list, not an empty environment.** Variables omitted from `Port.open/2` remain inherited from the Arbor VM, so passing only a pinned `PATH` still exposes ambient credentials to an authorized `printenv` child. Agent-facing sync, async, and streaming execution must force a shared deny-by-default environment that explicitly unsets inherited keys before adding the small internal allowlist; caller options and `sandbox: :none` must not disable it (found 2026-07-13 while designing the spawn-capable containment boundary).

<!-- applied-learning: contained-mix-executable-not-found-can-mean-the-pinned-container-runtime-not-mix -->
<a id="applied-learning-contained-mix-executable-not-found-can-mean-the-pinned-container-runtime-not-mix"></a>
**Contained Mix `:executable_not_found` can mean the pinned container runtime, not Mix.** `Arbor.Actions.Mix` already resolves the reviewed repository wrapper, but spawn containment separately requires the Apple-signed `container` CLI at the fixed `/usr/local/bin/container` authority path. An unsigned Homebrew binary at `/opt/homebrew/bin/container` is intentionally rejected; do not widen the path policy or fall back to host execution merely to make validation pass. Inspect `validate/status.json` and verify code signing/runtime installation before debugging the wrapper (confirmed 2026-07-15 after both coding-fix delegations reached validation).

<!-- applied-learning: apple-container-networking-must-request-the-reserved-none-network-explicitly -->
<a id="applied-learning-apple-container-networking-must-request-the-reserved-none-network-explicitly"></a>
**Apple `container` networking must request the reserved `none` network explicitly.** In `container` 1.1.0, omitting `--network` attaches the built-in `default` NAT network, while `--network none` is a reserved CLI value that sets the container's network attachments to an empty list. For spawn containment, require exactly `--network none` and prove the guest has no network interface; `--no-dns`, an omitted/empty option list, or an `--internal` network is a weaker policy (found 2026-07-13 while designing Spawn Containment Slice 2 against the official sources).

<!-- applied-learning: every-persistence-migration-must-run-on-every-supported-development-adapter -->
<a id="applied-learning-every-persistence-migration-must-run-on-every-supported-development-adapter"></a>
**Every persistence migration must run on every supported development adapter.** Arbor defaults to SQLite for zero-config development, and `ecto_sqlite3` rejects column `modify` operations that work on Postgres. A migration is not complete after a Postgres-only proof: run the full fresh-schema chain on both adapters, use adapter-specific DDL where necessary, and keep production-like data repair as a separate rehearsal (found 2026-07-13 when the records generation migration stopped a fresh SQLite runtime).

<!-- applied-learning: apple-container-create-treats-tokens-after-the-image-as-init-process-arguments -->
<a id="applied-learning-apple-container-create-treats-tokens-after-the-image-as-init-process-arguments"></a>
**Apple `container create` treats tokens after the image as init-process arguments.** A 1.1.0 live probe passed `--network default` after the immutable image while specifying `--network none` before it; `container inspect` recorded the former only in `initProcess.arguments` and kept `networks: []`. Keep every container-management option before the image and the fixed Mix arguments after it, and retain an exact argv test so future CLI/version changes cannot silently reinterpret command flags (verified 2026-07-14 while reviewing the Apple Container planner).

<!-- applied-learning: a-linux-containment-guest-cannot-reuse-an-unfiltered-macos-dependency-snapshot -->
<a id="applied-learning-a-linux-containment-guest-cannot-reuse-an-unfiltered-macos-dependency-snapshot"></a>
**A Linux containment guest cannot reuse an unfiltered macOS dependency snapshot.** The validation lease currently copies the host `deps/` tree, which can contain Darwin artifacts such as `sqlite_vec/priv/.../vec0.dylib`; rebuilding a missing Linux artifact can then invoke a dependency downloader despite the intended offline contract. Provision an attested Linux-native dependency baseline keyed to the exact `mix.lock` and immutable image digests, clone it into each private writable lease, and keep image/dependency provisioning outside authorized no-network execution (found 2026-07-14 before wiring Apple Container admission).

<!-- applied-learning: an-immutable-apple-container-image-reference-is-not-a-no-pull-guarantee -->
<a id="applied-learning-an-immutable-apple-container-image-reference-is-not-a-no-pull-guarantee"></a>
**An immutable Apple Container image reference is not a no-pull guarantee.** In Apple Container 1.1.0, `container create` calls `ClientImage.fetch` for the workload and vminit, and the API server fetches vminit again; a missing local reference therefore initiates a registry pull even when it contains `@sha256`. Use operator-provisioned execution aliases under the non-connectable loopback registry sink `127.0.0.1:0/...@sha256:...`, force `--scheme https`, and admit a proxy-free API/plugin launch environment so a missing alias fails locally. Bind each alias's descriptor/index/selected-manifest digests before use; preflight inspect alone does not remove the same-user store race (found 2026-07-14 auditing Apple Container 1.1.0 and containerization 0.35.0).

<!-- applied-learning: do-not-duplicate-the-native-launcher-s-final-executable-identity-check-in-executablepolicy -->
<a id="applied-learning-do-not-duplicate-the-native-launcher-s-final-executable-identity-check-in-executablepolicy"></a>
**Do not duplicate the native launcher's final executable identity check in `ExecutablePolicy`.** `ProcessGroup` passes the startup-pinned metadata and digest to `arbor_shell_launcher`, which opens the target, verifies the FD and current path against that identity immediately before execution, and uses `fexecve` on Linux (with the equivalent checked Darwin path handoff). `ExecutablePolicy.verify_pinned/1` is the membership/argument gate; rehashing there adds cost without closing the final race. Use `TrustedPath.verify_pinned/1` for other startup-pinned control-plane files that do not cross this native launcher boundary (clarified 2026-07-14 while reviewing the TrustedPath extraction).

<!-- applied-learning: structured-argv-does-not-require-whitespace-free-filesystem-paths -->
<a id="applied-learning-structured-argv-does-not-require-whitespace-free-filesystem-paths"></a>
**Structured argv does not require whitespace-free filesystem paths.** Apple Container's default application root is `~/Library/Application Support/com.apple.container`; rejecting whitespace in an otherwise canonical absolute path makes the stock service impossible to admit and does not add injection resistance when the path remains one argv/environment value. Bound byte length before UTF-8 or `Path` work, reject NUL/control bytes and non-canonical segments, and preserve valid spaces (found 2026-07-14 reviewing the Apple control-plane admission core against the 1.1.0 source).

<!-- applied-learning: single-quote-shell-search-patterns-that-contain-backticks -->
<a id="applied-learning-single-quote-shell-search-patterns-that-contain-backticks"></a>
**Single-quote shell search patterns that contain backticks.** Backticks still perform command substitution inside double quotes, including in an `rg` pattern. Use single quotes or escape each backtick so a diagnostic search cannot execute fragments from the pattern (found 2026-07-14 while auditing Apple Container source references).

<!-- applied-learning: a-trapped-process-that-runs-external-commands-will-receive-ordinary-port-exits -->
<a id="applied-learning-a-trapped-process-that-runs-external-commands-will-receive-ordinary-port-exits"></a>
**A trapped process that runs external commands will receive ordinary Port exits.** A broad `{:EXIT, _from, reason}` shutdown handler can mistake a completed `System.cmd/3` port for supervisor teardown and destroy live state mid-operation. Bind shutdown handling to the actual supervisor ancestor and ignore Port exits; monitor-based resource-owner death remains a separate message path (found 2026-07-16 implementing validation-resource crash cleanup).

<!-- applied-learning: repository-reconstruction-must-handle-safe-relative-symlinks-without-weakening-containment -->
<a id="applied-learning-repository-reconstruction-must-handle-safe-relative-symlinks-without-weakening-containment"></a>
**Repository reconstruction must handle safe relative symlinks without weakening containment.** Real repositories can contain links such as `AGENTS.md -> CLAUDE.md` or `.agents/skills -> ../.claude/skills`. Recreate only relative links whose normalized target stays inside the fixture root and outside `.git`; reject absolute targets, escapes, and Git-metadata targets rather than banning all symlinks or following them during copy (found 2026-07-16 preparing real Arbor benchmark fixtures).

<!-- applied-learning: prime-apple-container-s-builder-explicitly-on-first-use -->
<a id="applied-learning-prime-apple-container-s-builder-explicitly-on-first-use"></a>
**Prime Apple Container's builder explicitly on first use.** Inspect `container system property list`, pull the configured builder image with bounded download concurrency, then run `container builder start` before the first build. Otherwise the automatic pull/start path can look like a missing BuildKit runtime or a hung build (found 2026-07-16 provisioning the standalone Apple Container 1.1.0 runtime).

<!-- applied-learning: a-trusted-bootstrap-cli-that-forks-needs-a-closed-process-tree-primitive-not-a-generic-no-fork-bypass -->
<a id="applied-learning-a-trusted-bootstrap-cli-that-forks-needs-a-closed-process-tree-primitive-not-a-generic-no-fork-bypass"></a>
**A trusted bootstrap CLI that forks needs a closed process-tree primitive, not a generic no-fork bypass.** Arbor's generic direct executor deliberately denies `fork`/`clone`; routing the signed Apple `container system status` probe through it returned `EPERM` before admission even though the exact command succeeded with an empty environment. Keep generic Shell and agent execution childless, and give only the pinned control-plane executable plus exact read-only argv shapes a bounded descendant-tracking runner with the same identity, deadline, output, and teardown guarantees (found 2026-07-16 during the Slice 2D live matrix).

<!-- applied-learning: apple-container-1-1-virtiofs-bind-sources-must-be-directories -->
<a id="applied-learning-apple-container-1-1-virtiofs-bind-sources-must-be-directories"></a>
**Apple Container 1.1 virtiofs bind sources must be directories.** Mounting the reviewed `bin/mix` file directly made `container create` fail with `path '.../bin/mix' is not a directory`. Keep Actions/tool authority bound to the exact wrapper file, then derive its canonical non-root parent at the pure execution-to-plan boundary and mount that directory read-only at `/arbor/bin`; the fixed entrypoint remains `/arbor/bin/mix` (found 2026-07-16 during the Slice 2D live matrix).

<!-- applied-learning: prove-descendant-requirements-per-exact-cli-subcommand-before-expanding-fork-authority -->
<a id="applied-learning-prove-descendant-requirements-per-exact-cli-subcommand-before-expanding-fork-authority"></a>
**Prove descendant requirements per exact CLI subcommand before expanding fork authority.** Apple `container system status` fails under the generic no-fork runner, but the exact reviewed `list`, corrected `create`, and `start --attach` argv all succeeded through that same generic runner. A shared executable does not imply shared process behavior; reproduce the exact command before adding another fork-permitting launcher mode (found 2026-07-16 during the Slice 2D live matrix).

<!-- applied-learning: one-shot-stdin-must-make-progress-concurrently-with-child-stdout -->
<a id="applied-learning-one-shot-stdin-must-make-progress-concurrently-with-child-stdout"></a>
**One-shot stdin must make progress concurrently with child stdout.** Sending one large launcher input packet lets the launcher block writing the child's stdin while a duplex child blocks on its full stdout pipe. Small control frames and output-first ordering are not sufficient if the launcher then performs a blocking write to child stdin: a real 3,457-object Git batch still deadlocked after the 8 KiB framing fix. Keep the child-stdin descriptor nonblocking, retain at most one bounded pending frame, and poll its `POLLOUT` alongside child output and controller HUP so timeout and owner-loss containment remain live under backpressure. Chunk both initial and interactive input at the same native bound, and regress with a duplex round-trip comfortably above OS pipe capacity; small 48-object fixtures can pass while production scale deadlocks (found 2026-07-16 and reproduced by real-scale Phase 6 fixture preparation on 2026-07-18).

<!-- applied-learning: a-contained-mix-guest-must-own-every-executable-tool-it-needs -->
<a id="applied-learning-a-contained-mix-guest-must-own-every-executable-tool-it-needs"></a>
**A contained Mix guest must own every executable tool it needs.** `AppleContainerPlanCore` reconstructs a closed guest environment, so a host `MIX_ARCHIVES` value does not cross the boundary. A materialized dependency tree alone is insufficient when Mix cannot load Hex/Rebar or a dependency falls back to native compilation/download. Put Hex, Rebar, Linux build tools and headers, and checksum-verified precompiled NIF archives in the immutable Linux image; expose only fixed guest `MIX_HOME`, `MIX_ARCHIVES`, and `ELIXIR_MAKE_CACHE_DIR` values; then prove an empty-build compile with networking disabled (found 2026-07-16/17 during Phase 6 cross-app dogfood).

<!-- applied-learning: schema-bounded-mix-test-paths-require-an-explicit-argv-delimiter -->
<a id="applied-learning-schema-bounded-mix-test-paths-require-an-explicit-argv-delimiter"></a>
**Schema-bounded Mix test paths require an explicit argv delimiter.** The Apple Container admission grammar accepts test paths only after `--`, so action producers must emit `["test", "--", path]`; `["test", path]` fails before Mix starts with `:unsupported_mix_command`. Keep the delimiter in boundary tests and diagnose a later test timeout from the captured child output rather than assuming the path was ignored (found 2026-07-17 during cross-app validation dogfood).

<!-- applied-learning: apple-container-virtiofs-bind-mounts-do-not-provide-stable-inode-identity -->
<a id="applied-learning-apple-container-virtiofs-bind-mounts-do-not-provide-stable-inode-identity"></a>
**Apple Container virtiofs bind mounts do not provide stable inode identity.** Consecutive guest metadata reads of one host-bound path can report different inode values, so `OwnedTree` correctly fails closed when an identity-sensitive temporary tree is projected through virtiofs. Keep the owner-scoped host tmp resource for lifecycle accounting, but give the guest a private tmpfs and keep that tmpfs out of the host bind-projection model (found 2026-07-17 during Phase 6 contained validation).

<!-- applied-learning: prove-container-mounts-under-a-read-only-root -->
<a id="applied-learning-prove-container-mounts-under-a-read-only-root"></a>
**Prove container mounts under a read-only root.** A writable image directory can make an invalid or ignored mount option appear successful. Verify the exact CLI argv with a read-only root, inspect `/proc/mounts`, confirm the expected mode, and perform a write; Apple Container 1.1.0 accepts `--tmpfs /tmp` as a path-only pair, while Docker-style `:size=...,mode=...` text leaves `/tmp` read-only (found 2026-07-17 while correcting the guest tmpfs planner).

<!-- applied-learning: exact-security-inventories-should-be-batched-before-expensive-contained-execution -->
<a id="applied-learning-exact-security-inventories-should-be-batched-before-expensive-contained-execution"></a>
**Exact security inventories should be batched before expensive contained execution.** Git tracked/untracked enumeration plus segment/path/lstat verification is the authorization boundary; one container per verified file is merely an execution strategy and can make a bounded stage structurally impossible. Preserve the exact verified argv entries, then partition them by closed file-count and argument-byte limits so each child remains bounded while container startup is amortized (found 2026-07-17 when per-file Apple Container lifecycle overhead exhausted a 20-minute stage after only a small fraction of 511 files).

<!-- applied-learning: mix-run-retains-the-script-argument-in-system-argv-0 -->
<a id="applied-learning-mix-run-retains-the-script-argument-in-system-argv-0"></a>
**`mix run` retains the script-argument `--` in `System.argv/0`.** For `mix run --no-start runner.exs -- result.etf tests...`, strip exactly one leading separator, validate and store the owner-issued result path before `Mix.Task.run/2`, and never reread argv from an ExUnit completion callback because the nested Mix task may replace it (found 2026-07-18 repairing the two-revision security-regression harness).

<!-- applied-learning: a-raw-elixir-sigil-does-not-escape-the-outer-shell-quote -->
<a id="applied-learning-a-raw-elixir-sigil-does-not-escape-the-outer-shell-quote"></a>
**A raw Elixir sigil does not escape the outer shell quote.** When the whole `arbor.rpc` expression is enclosed in shell single quotes, an apostrophe anywhere inside the `~S|...|` message still terminates the shell argument before Elixir sees it. Either keep the message apostrophe-free, or construct the argv without a shell-quoted expression; raw sigils solve Elixir quoting only (found 2026-07-18 steering the security-regression test-seam follow-up).

<!-- applied-learning: a-hermetic-mix-shell-seam-must-own-wrapper-resolution-as-well-as-execution -->
<a id="applied-learning-a-hermetic-mix-shell-seam-must-own-wrapper-resolution-as-well-as-execution"></a>
**A hermetic Mix shell seam must own wrapper resolution as well as execution.** Replacing `:mix_shell_module` alone is insufficient when projection construction resolves the production wrapper before the configured shell runs. Let the same trusted named shell optionally resolve the exact wrapper it accepts, validate that result at the action boundary, and thread one validated identity through both filesystem projections and execution; keep the public production resolver code-root-only (found 2026-07-18 in `task_1992`).

<!-- applied-learning: the-working-grok-no-shell-boundary-is-an-attested-arbor-owned-profile -->
<a id="applied-learning-the-working-grok-no-shell-boundary-is-an-attested-arbor-owned-profile"></a>
**The working Grok no-shell boundary is an attested Arbor-owned profile.** Stage a private `0600` `--agent-profile` with exact bytes, path, type, and mode attested at launch and reconnect; expose native file tools while disallowing `run_terminal_cmd`, `task`, `get_task_output`, and `kill_task`. The proof must be capability-backed and include both a denied terminal marker and a successful native edit (found 2026-07-19 during Grok ACP containment work).
