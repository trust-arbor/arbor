# Applied Learning: Shell and Containment

Read this when executing commands, configuring process or container containment, or validating executable identity and resource bounds.

## Retained Applied Learning

<!-- applied-learning: mix-app-optional-applications-overlap-applications -->
<a id="applied-learning-mix-app-optional-applications-overlap-applications"></a>
**Mix `.app` files list present optional deps in both `applications` and
`optional_applications`.** Treating those lists as pairwise-disjoint rejects
real tesla/jason/ecto/postgrex specs. Hard-required deps are
`applications − optional_applications`, plus `included_applications`. OTP
still forbids `applications` ∩ `included_applications`. Hex also emits
`compile_env`, `doc`, and `include_files` as top-level keys (found 2026-08-17
during E0B2C `--write`).

<!-- applied-learning: trusted-build-deps-are-writable-after-compile -->
<a id="applied-learning-trusted-build-deps-are-writable-after-compile"></a>
**Trusted-build deps inventory is a pre-compile snapshot, not a post-compile
pin.** `elixir_make` / `exqlite` / Mix `project/0` write into the writable
deps root during compile. Compare that inventory at compile *start* (two-build
equality). After compile has completed, do not re-require the pre-compile
digest on release, release inventory, or cleanup attestation (found 2026-08-17
when compose compile succeeded then `after_mix_success` returned
`:identity_mismatch`).

<!-- applied-learning: mix-release-strip-beams-keeps-attr-lease-paths -->
<a id="applied-learning-mix-release-strip-beams-keeps-attr-lease-paths"></a>
**Mix release `strip_beams` still leaves lease-absolute paths in Attr,
Line, LitT, and `sys.config`.** `use Boundary` persists `env.file`, Hex
packages persist `@external_resource` from `__DIR__`, and generated
modules keep the compile file in Line/LitT. Replace those prefixes
with same-length canonical tokens before release inventory so two
isolated leases compare equal (found 2026-08-17 during E0B2C `--write`).

<!-- applied-learning: a-hex-lock-does-not-attest-compile-time-native-downloads -->
<a id="applied-learning-a-hex-lock-does-not-attest-compile-time-native-downloads"></a>
**A Hex lock does not attest compile-time native downloads.** A locked Hex package
can invoke a build provider that fetches a second native archive outside Hex's
checksum. `membrane_portaudio_plugin` 0.19.6 selects a PortAudio 19.7.0 URL and
Bundlex 1.5.8 downloads and extracts it without comparing a declared content digest.
For no-network contained builds, disable unverified precompiled OS dependencies and
provide the exact library through the immutable image/pkg-config path, or introduce
an explicit checksum-bound artifact admission. Never treat `mix.lock` alone as proof
of the resulting NIF's native inputs (found 2026-08-03 during Voice VP-07 dependency
preflight).

<!-- applied-learning: a-silent-macos-say-probe-needs-a-real-audio-file-suffix -->
<a id="applied-learning-a-silent-macos-say-probe-needs-a-real-audio-file-suffix"></a>
**A silent macOS `say` probe needs a real audio-file suffix.** Startup-pinned
`/usr/bin/say` works through `Arbor.Shell.execute_direct/3` with a cleared
environment and bounded one-shot stdin, but `say -o /dev/null` exits 1 with
`Speaking failed: -241` because the destination supplies no usable audio format.
For a non-audible containment probe, use an owner-generated unique `.aiff` path,
assert normal terminal metadata plus nonzero output bytes, and remove that exact
file in an `after` block. Do not diagnose the `/dev/null` result as launcher or
stdin containment failure (verified 2026-08-03 during Voice VP-07 preflight).

<!-- applied-learning: transient-authority-capacity-failures-are-not-integrity-drift -->
<a id="applied-learning-transient-authority-capacity-failures-are-not-integrity-drift"></a>
**Transient authority capacity failures are not integrity drift.** A serialized
startup-pinned verifier can legitimately exceed the default five-second
`GenServer.call` timeout under concurrent validation. Fail the requesting
operation closed, but poison the boot epoch only for positive integrity
evidence such as a verified receipt mismatch or malformed trusted state. Use a
system-owned bounded call timeout sized for the verifier's measured work, and
regress that transient unavailability preserves the pinned owner while real
drift still tears down later owners (found 2026-07-29 when two parallel coding
validations timed out baseline checkout, poisoned image-policy authority, and
restarted `ExecutionRegistry`).

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

<!-- applied-learning: basic-shell-sandbox-checks-the-command-string-even-after-argument-escaping -->
<a id="applied-learning-basic-shell-sandbox-checks-the-command-string-even-after-argument-escaping"></a>
**Basic-shell sandbox checks the command string even after argument escaping.** `ShellEscape` single-quotes dangerous commit-message text correctly, but `Arbor.Shell.Sandbox` still rejects metacharacters like backticks inside the assembled command string. Git actions that run via `Shell.execute(..., sandbox: :basic)` need to normalize user/task-derived arguments such as commit messages before constructing the shell command, or use a non-shell argv execution path.

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
**Quote shell search patterns so documentation backticks stay literal.** A double-quoted shell string executes backticks. Single-quote a pattern that must stay literal. A raw Elixir sigil does not escape the quote of the outer shell: `mix arbor.rpc` evaluates the remote expression, and a backtick inside the local command line is still the shell's command substitution before Mix sees it. Prefer structured argv, such as `Arbor.Shell.execute_direct/3`, whenever inner quoting cannot protect the outer shell. Count every parser between the operator command and the program under test. (Merged 2026-10-16 from 3 entries; first found 2026-07-10, last 2026-07-18.)

<!-- applied-learning: a-signed-capability-manifest-must-bind-the-exact-executable-artifact-and-inputs -->
<a id="applied-learning-a-signed-capability-manifest-must-bind-the-exact-executable-artifact-and-inputs"></a>
**A signed capability manifest must bind the exact executable artifact and inputs.** Signing only a list of allowed capabilities lets the same valid manifest be copied beside different DOT or reused with a different workdir/argument payload. Scheduled/custom graph attestations must cover canonical graph bytes/hash, pipeline identity, fixed workdir, and the reviewed argument contract, then recheck the hash immediately before execution (found 2026-07-10 auditing the scheduler DOT-authorship redesign).

<!-- applied-learning: read-contained-files-through-safepath-pinned-readers-not-resolve-then-read -->
<a id="applied-learning-read-contained-files-through-safepath-pinned-readers-not-resolve-then-read"></a>
**Read contained files through `SafePath`'s pinned readers, not resolve-then-read.** `Arbor.Common.SafePath.resolve_within/2` returns the symlink-resolved canonical target, but resolving a path and then calling `File.read/1` still leaves a window in which another process can swap the file, an ancestor, or the root. For a user-selected path, authorize the caller-visible path through the fs/`Arbor.Security.FileGuard` gate, then read with `SafePath.read_within_checked/3`: it opens the file relative to a pinned root descriptor with `O_NOFOLLOW` and runs your validator against the exact opened canonical path before any data is read. Use `SafePath.read_exact/2` when the leaf itself must not be a link, and `SafePath.bind_root/1` with `read_within_bound_checked/3` when the root must stay the same directory object across calls. To detect redirection without reading, compare `SafePath.lexical_child/2` with `SafePath.resolve_real/1`. (Replaces the 2026-07-10 lexical-containment entry; rewritten 2026-10-16 against current `safe_path.ex`.)

<!-- applied-learning: a-bound-nested-graph-is-immutable-executable-input -->
<a id="applied-learning-a-bound-nested-graph-is-immutable-executable-input"></a>
**A bound nested graph is immutable executable input.** Do not rewrite node attributes such as question, mode, or quorum after the parent manifest has attested the child graph; even semantically equivalent mutation changes the compiled object and correctly fails binding verification. Put per-run data in the child's initial context, reject executable overrides on bound paths, and preserve custom graph mutation only for explicitly unbound execution (found 2026-07-10 while dogfooding the bound coding-review council).

<!-- applied-learning: authority-key-scanners-must-distinguish-executable-control-data-from-declarative-schemas -->
<a id="applied-learning-authority-key-scanners-must-distinguish-executable-control-data-from-declarative-schemas"></a>
**Authority-key scanners must distinguish executable control data from declarative schemas.** Recursively flagging every key named `agent_id` or `owner` across a compiler artifact rejects legitimate action JSON Schema properties even though those names never become runtime values. Scan the plan/compiler control envelope, and validate trusted descriptor or execution-manifest subtrees with their exact structural/catalog validators instead of applying control-key heuristics to schema vocabulary (found 2026-07-10 when the live CodingPlan catalog included `council_review_change.agent_id` and `git_pr.owner`).

<!-- applied-learning: module-atoms-are-executable-selectors-not-inert-descriptor-data -->
<a id="applied-learning-module-atoms-are-executable-selectors-not-inert-descriptor-data"></a>
**Module atoms are executable selectors, not inert descriptor data.** Pin every executable module or MFA at the trusted owner's initialization boundary. Per-task and per-dispatch descriptors carry only validated scalar provenance. They must not carry a caller-chosen cleanup MFA or an anonymous closure. Launch deferred work with a module, function, and args chosen by the owner. Cleanup code selected by the dispatch payload runs with the owner's authority. A private option map is still an authority channel when applying it selects code. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: acceptance-must-be-derived-from-evidence-never-trusted-from-a-report-summary -->
<a id="applied-learning-acceptance-must-be-derived-from-evidence-never-trusted-from-a-report-summary"></a>
**Acceptance must be derived from evidence, never trusted from a report summary.** A deterministic benchmark can execute nothing yet pass if `acceptance/1` reads only caller-supplied aggregate counts. Validate a closed, non-empty row/pair schema, recompute every aggregate from status-specific objective/lifecycle/artifact checks, and reject summaries that do not exactly match the derived result (found 2026-07-11 reviewing the coding conformance benchmark).

<!-- applied-learning: disable-the-authority-mismatch-not-only-one-compound-shell-implementation -->
<a id="applied-learning-disable-the-authority-mismatch-not-only-one-compound-shell-implementation"></a>
**Reject every agent-facing compound shell, not only one implementation.** `Arbor.Shell.CapShell` returns `{:error, {:compound_shell_unavailable, :security_boundary_incomplete}}`. `Arbor.Shell.Sandbox` rejects compounds, including at sandbox `:none`, before approvals, temporary files, sessions, or processes. Apply that same fail-closed rejection to every agent-facing compound, wrapper, and dynamically expanded shell path: CapShell, script execution, async and streaming shell, and the DOT shell handler. A command-name policy cannot enforce a safety floor that depends on arguments. Unchecked compounds stay limited to explicit trusted-system APIs. Keep CapShell fail-closed. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: a-port-env-option-is-an-override-list-not-an-empty-environment -->
<a id="applied-learning-a-port-env-option-is-an-override-list-not-an-empty-environment"></a>
**A Port `:env` option is an override list, not an empty environment.** Variables omitted from `Port.open/2` remain inherited from the Arbor VM, so passing only a pinned `PATH` still exposes ambient credentials to an authorized `printenv` child. Agent-facing sync, async, and streaming execution must force a shared deny-by-default environment that explicitly unsets inherited keys before adding the small internal allowlist; caller options and `sandbox: :none` must not disable it (found 2026-07-13 while designing the spawn-capable containment boundary).

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
**An immutable Apple Container image reference is not a no-pull guarantee.** In Apple Container 1.1.0, `container create` calls `ClientImage.fetch` for the workload and vminit, and the API server fetches vminit again; a missing local reference therefore initiates a registry pull even when it contains `@sha256`. Use operator-provisioned execution aliases under the non-connectable loopback registry sink `127.0.0.1:0/...@sha256:...`, force `--scheme https`, and admit a proxy-free API/plugin launch environment so a missing alias fails locally. Apple Container's image store does not treat a normal tag under that repository as equivalent to the digest-qualified reference: create and inspect the exact `repository@sha256:<index>` alias before activation. Bind each alias's descriptor/index/selected-manifest digests before use; preflight inspect alone does not remove the same-user store race (found 2026-07-14 auditing Apple Container 1.1.0 and containerization 0.35.0; extended 2026-08-20 after a tag-only baseline promotion passed file/config activation but failed the admission probe).

<!-- applied-learning: do-not-duplicate-the-native-launcher-s-final-executable-identity-check-in-executablepolicy -->
<a id="applied-learning-do-not-duplicate-the-native-launcher-s-final-executable-identity-check-in-executablepolicy"></a>
**Do not duplicate the native launcher's final executable identity check in `ExecutablePolicy`.** `ProcessGroup` passes the startup-pinned metadata and digest to `arbor_shell_launcher`, which opens the target, verifies the FD and current path against that identity immediately before execution, and uses `fexecve` on Linux (with the equivalent checked Darwin path handoff). `ExecutablePolicy.verify_pinned/1` is the membership/argument gate; rehashing there adds cost without closing the final race. Use `TrustedPath.verify_pinned/1` for other startup-pinned control-plane files that do not cross this native launcher boundary (clarified 2026-07-14 while reviewing the TrustedPath extraction).

<!-- applied-learning: structured-argv-does-not-require-whitespace-free-filesystem-paths -->
<a id="applied-learning-structured-argv-does-not-require-whitespace-free-filesystem-paths"></a>
**Structured argv does not require whitespace-free filesystem paths.** Apple Container's default application root is `~/Library/Application Support/com.apple.container`; rejecting whitespace in an otherwise canonical absolute path makes the stock service impossible to admit and does not add injection resistance when the path remains one argv/environment value. Bound byte length before UTF-8 or `Path` work, reject NUL/control bytes and non-canonical segments, and preserve valid spaces (found 2026-07-14 reviewing the Apple control-plane admission core against the 1.1.0 source).

<!-- applied-learning: a-trapped-process-that-runs-external-commands-will-receive-ordinary-port-exits -->
<a id="applied-learning-a-trapped-process-that-runs-external-commands-will-receive-ordinary-port-exits"></a>
**A trapped process that runs external commands will receive ordinary Port exits.** A broad `{:EXIT, _from, reason}` shutdown handler can mistake a completed `System.cmd/3` port for supervisor teardown and destroy live state mid-operation. Bind shutdown handling to the actual supervisor ancestor and ignore Port exits; monitor-based resource-owner death remains a separate message path (found 2026-07-16 implementing validation-resource crash cleanup).

<!-- applied-learning: repository-reconstruction-must-handle-safe-relative-symlinks-without-weakening-containment -->
<a id="applied-learning-repository-reconstruction-must-handle-safe-relative-symlinks-without-weakening-containment"></a>
**Repository reconstruction must handle safe relative symlinks without weakening containment.** Real repositories can contain links such as `AGENTS.md -> CLAUDE.md` or `.agents/skills -> ../.claude/skills`. Recreate only relative links whose normalized target stays inside the fixture root and outside `.git`; reject absolute targets, escapes, and Git-metadata targets rather than banning all symlinks or following them during copy (found 2026-07-16 preparing real Arbor benchmark fixtures).

<!-- applied-learning: a-trusted-bootstrap-cli-that-forks-needs-a-closed-process-tree-primitive-not-a-generic-no-fork-bypass -->
<a id="applied-learning-a-trusted-bootstrap-cli-that-forks-needs-a-closed-process-tree-primitive-not-a-generic-no-fork-bypass"></a>
**A forking trusted CLI needs a closed process-tree primitive.** `Arbor.Shell.execute_direct/3` is childless. Killing the port owner does not prove that descendants stopped. Grant descendant execution only through `execute_spawn_capable/3` for an exact reviewed executable and argv, and prove that requirement per subcommand before widening fork authority. Do not lift the generic no-fork rule to accommodate one probe. Every terminal path — timeout, cancellation, launcher failure, and owner loss — must show bounded, escape-resistant exhaustion of that whole process tree. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-16.)

<!-- applied-learning: apple-container-1-1-virtiofs-bind-sources-must-be-directories -->
<a id="applied-learning-apple-container-1-1-virtiofs-bind-sources-must-be-directories"></a>
**Apple Container 1.1 virtiofs bind sources must be directories.** Mounting the reviewed `bin/mix` file directly made `container create` fail with `path '.../bin/mix' is not a directory`. Keep Actions/tool authority bound to the exact wrapper file, then derive its canonical non-root parent at the pure execution-to-plan boundary and mount that directory read-only at `/arbor/bin`; the fixed entrypoint remains `/arbor/bin/mix` (found 2026-07-16 during the Slice 2D live matrix).

<!-- applied-learning: one-shot-stdin-must-make-progress-concurrently-with-child-stdout -->
<a id="applied-learning-one-shot-stdin-must-make-progress-concurrently-with-child-stdout"></a>
**One-shot stdin must make progress concurrently with child stdout.** Sending one large launcher input packet lets the launcher block writing the child's stdin while a duplex child blocks on its full stdout pipe. Small control frames and output-first ordering are not sufficient if the launcher then performs a blocking write to child stdin: a real 3,457-object Git batch still deadlocked after the 8 KiB framing fix. Keep the child-stdin descriptor nonblocking, retain at most one bounded pending frame, and poll its `POLLOUT` alongside child output and controller HUP so timeout and owner-loss containment remain live under backpressure. Chunk both initial and interactive input at the same native bound, and regress with a duplex round-trip comfortably above OS pipe capacity; small 48-object fixtures can pass while production scale deadlocks (found 2026-07-16 and reproduced by real-scale Phase 6 fixture preparation on 2026-07-18).

<!-- applied-learning: a-contained-mix-guest-must-own-every-executable-tool-it-needs -->
<a id="applied-learning-a-contained-mix-guest-must-own-every-executable-tool-it-needs"></a>
**A contained Mix guest must own every executable it will run.** Install Hex, Rebar, build tools, and checksum-bound native assets in the immutable image. `HEX_OFFLINE=1` in `Arbor.Shell.TrustedBuild.Plan` does not disable dependency runtime networking by itself. Export only the fixed guest `MIX_HOME`, `MIX_ARCHIVES`, and `ELIXIR_MAKE_CACHE_DIR` (`Arbor.Shell.AppleContainerPlanCore`); omitting the cache directory makes a precompiled NIF look missing. Use a private writable build parent, not one child of a shared parent. `System.cmd("kill")` requires an image executable, not a shell builtin. `File.chmod/2` strips sticky bits; set them with the OS chmod sticky-bit mode and check with `stat`. Disable runtime network refresh before application startup, assert those workers are absent, and keep seed data frozen. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-09-08.)

<!-- applied-learning: smoke-test-a-disposable-copy-of-a-dependency-baseline-never-the-source-to-be-signed -->
<a id="applied-learning-smoke-test-a-disposable-copy-of-a-dependency-baseline-never-the-source-to-be-signed"></a>
**Smoke-test a disposable copy of a dependency baseline, never the source to be signed.** Mix and Rebar compilation can mutate dependency source directories with nested `_build` trees and generated lexer/parser files even when `MIX_BUILD_PATH` points elsewhere. Build the canonical platform-native source, copy it for the no-network empty-build proof, discard that proof copy, then generate the manifest from the untouched canonical tree and verify its digest immediately before root installation (found 2026-08-02 repairing the Linux `sqlite_vec` baseline).

<!-- applied-learning: schema-bounded-mix-test-paths-require-an-explicit-argv-delimiter -->
<a id="applied-learning-schema-bounded-mix-test-paths-require-an-explicit-argv-delimiter"></a>
**Schema-bounded Mix test paths require an explicit argv delimiter.** The Apple Container admission grammar accepts test paths only after `--`, so action producers must emit `["test", "--", path]`; `["test", path]` fails before Mix starts with `:unsupported_mix_command`. Keep the delimiter in boundary tests and diagnose a later test timeout from the captured child output rather than assuming the path was ignored (found 2026-07-17 during cross-app validation dogfood).

<!-- applied-learning: apple-container-virtiofs-bind-mounts-do-not-provide-stable-inode-identity -->
<a id="applied-learning-apple-container-virtiofs-bind-mounts-do-not-provide-stable-inode-identity"></a>
**Apple Container virtiofs bind mounts do not provide stable inode identity.** Consecutive guest metadata reads of one host-bound path can report different inode values, so `OwnedTree` correctly fails closed when an identity-sensitive temporary tree is projected through virtiofs. Keep the owner-scoped host tmp resource for lifecycle accounting, but give the guest a private tmpfs and keep that tmpfs out of the host bind-projection model (found 2026-07-17 during Phase 6 contained validation).

<!-- applied-learning: prove-container-mounts-under-a-read-only-root -->
<a id="applied-learning-prove-container-mounts-under-a-read-only-root"></a>
**Prove container mounts under a read-only root.** A writable image directory can make an invalid or ignored mount option appear successful. Verify the exact CLI argv with a read-only root, inspect `/proc/mounts`, confirm the expected mode, and perform a write; Apple Container 1.1.0 accepts `--tmpfs /tmp` as a path-only pair, while Docker-style `:size=...,mode=...` text leaves `/tmp` read-only (found 2026-07-17 while correcting the guest tmpfs planner).

<!-- applied-learning: mix-run-retains-the-script-argument-in-system-argv-0 -->
<a id="applied-learning-mix-run-retains-the-script-argument-in-system-argv-0"></a>
**`mix run` retains the script-argument `--` in `System.argv/0`.** For `mix run --no-start runner.exs -- result.etf tests...`, strip exactly one leading separator, validate and store the owner-issued result path before `Mix.Task.run/2`, and never reread argv from an ExUnit completion callback because the nested Mix task may replace it (found 2026-07-18 repairing the two-revision security-regression harness).

<!-- applied-learning: a-hermetic-mix-shell-seam-must-own-wrapper-resolution-as-well-as-execution -->
<a id="applied-learning-a-hermetic-mix-shell-seam-must-own-wrapper-resolution-as-well-as-execution"></a>
**A hermetic Mix shell seam must own wrapper resolution as well as execution.** Replacing `:mix_shell_module` alone is insufficient when projection construction resolves the production wrapper before the configured shell runs. Let the same trusted named shell optionally resolve the exact wrapper it accepts, validate that result at the action boundary, and thread one validated identity through both filesystem projections and execution; keep the public production resolver code-root-only (found 2026-07-18 in `task_1992`).

<!-- applied-learning: classify-validation-capacity-only-from-trusted-shell-termination-flags -->
<a id="applied-learning-classify-validation-capacity-only-from-trusted-shell-termination-flags"></a>
**Classify validation capacity only from trusted Shell termination flags.** Exit
137 is ambiguous and can be produced by the program itself; output text is
candidate-controlled. Project `validation_capacity_exceeded` only when Shell
sets an exact boolean timeout, kill, output-limit, or cancellation flag, carry a
closed JSON-clean termination envelope, and otherwise preserve the ordinary
compile failure. Route trusted capacity terminals directly to owner recovery
without consuming worker rework (found 2026-07-28 after a default compile hit
its exact stage deadline and was incorrectly treated as a code defect).

<!-- applied-learning: inspect-the-source-owned-containment-unit-before-calling-a-long-validation-stalled -->
<a id="applied-learning-inspect-the-source-owned-containment-unit-before-calling-a-long-validation-stalled"></a>
**Inspect the source-owned containment unit before calling a long validation
stalled.** Pipeline status can remain at `validate` and RecoveryCoordinator can
report a stale heartbeat while a synchronous Apple Container unit is still
legitimately running under its exact operation deadline. Identify the node
process from bounded server telemetry, inspect only `Process.info/2`
status/current function and the supervised unit's redacted `:sys.get_state/2`
status, active phase, terminal, and remaining deadline; do not print argv or
mutate the unit. Treat owner-connected plus running unit plus positive remaining
budget as active, then rely on trusted terminal flags for the final capacity
classification (found 2026-07-28 while the budget-separation canary spent 547
seconds in a cold contained compile).

<!-- applied-learning: degraded-inventory-views-must-preserve-the-requested-scope -->
<a id="applied-learning-degraded-inventory-views-must-preserve-the-requested-scope"></a>
**Degraded inventory views must preserve the requested scope.** A poisoned,
disabled, or unavailable owner may return less evidence, but rebuilding an
empty default projection can silently widen a scoped query to global. Validate
the caller's filters and preserve the normalized mode and bounds in every
status response; degradation may reduce evidence, never broaden visibility
(found 2026-07-28 reviewing Apple Container unit inventory).

<!-- applied-learning: privileged-approval-must-not-execute-mutable-user-owned-inputs -->
<a id="applied-learning-privileged-approval-must-not-execute-mutable-user-owned-inputs"></a>
**Privileged approval must not execute mutable user-owned inputs.** An
administrator dialog can remain open while a referenced script, archive, or
configuration under a user-writable path changes. Copy the launcher into a
privileged process-created temporary file, verify that copied file against a
digest embedded in the already-issued authorization command, and execute only
the verified copy. The launcher must likewise copy every payload into
privileged staging and verify its pinned digest before extraction or
installation; checking a source path and then reopening it leaves the same
TOCTOU window (found 2026-07-31 while refreshing the Apple Container
dependency baseline).

<!-- applied-learning: secrets-must-not-be-passed-or-printed-in-process-argv -->
<a id="applied-learning-secrets-must-not-be-passed-or-printed-in-process-argv"></a>
**Secrets must not be passed or printed in process argv.** An Erlang distribution cookie in argv is remote-code-execution authority, including when an operator supplied it. Deliver secrets through a permissioned file or a post-spawn channel, and construct argv structurally with `Arbor.Shell.execute_direct/3` rather than a shell string. Diagnostics record bounded metadata — pid, elapsed time, command name, cwd, and task telemetry — and never the full command line. Redact argv when a diagnostic cannot avoid holding it. (Merged 2026-10-16 from 2 entries; first found 2026-07-28, last 2026-08-02.)

<!-- applied-learning: validation-readiness-must-exercise-the-final-admission-boundary -->
<a id="applied-learning-validation-readiness-must-exercise-the-final-admission-boundary"></a>
**Validation readiness must exercise the final admission boundary.** A healthy
container control plane proves only that its service and executable are
available; it does not prove that image policy and workload admission will
succeed. Invoke the same bounded admission probe required by the operation and
accept only its fully pinned result. Unsupported, unavailable, malformed, and
raced status must fail closed rather than letting expensive work discover the
problem later (found 2026-08-28 when Apple control-plane status was pinned while
CrossApp workload image policy was unavailable).
When promoting a new image, compare its complete reviewed environment and labels with the candidate policy; inheriting the predecessor policy can retain an obsolete PATH or omit admitted Mix/cache variables even when all image digests are correct (reinforced 2026-09-27 during native-audio baseline admission).
Preflight added containment with a no-effect child before mutating artifacts.
On 2026-10-05, nested `sandbox-exec` around `/usr/bin/true` failed with
`sandbox_apply` EPERM under Codex's existing sandbox, before any VM started.
Preserve that refusal. A reviewed no-start compiler already covered by the
required outer workspace/network restrictions can omit the unsupported nested
wrapper while retaining its executor-context and source/operation gates; this
does not authorize permission or outbound allowance changes.
Scope evidence to the actual probe. On 2026-10-06 the isolated Home regression
verified inherited TCP-listen denial before running, without starting Arbor or
calling providers or the live database. That denied listen is not proof that
every outbound network operation is blocked; retain the nested initialization
refusal separately from the passing test result.

<!-- applied-learning: image-policy-stores-provisioning-references-not-derived-execution-aliases -->
<a id="applied-learning-image-policy-stores-provisioning-references-not-derived-execution-aliases"></a>
**Image policy stores provisioning references, not derived execution aliases.**
Keep the operator-reviewed external digest-pinned image reference as policy,
then derive the non-connectable local execution alias only after verified
provisioning inside the runtime authority. Promotion prepare and activation
must reject local aliases in the policy source; writing derived state back into
policy conflates trust planes and makes a valid provisioned image inadmissible
(found 2026-08-28 when baseline promotion installed a `127.0.0.1:0` workload
alias as `image_policy.image`).

<!-- applied-learning: final-publication-proofs-must-reassert-frozen-security-invariants -->
<a id="applied-learning-final-publication-proofs-must-reassert-frozen-security-invariants"></a>
**Final publication proofs must reassert frozen security invariants.** Proving
that a held descriptor and its current pathname have equal `stat` fields does
not prove that either still satisfies the admitted state: both observations can
agree after a racer adds a hardlink or changes ownership or mode. Immediately
before reporting success, independently revalidate type, effective-user
ownership where required, link count, expected mode/size, and every frozen
identity field; a mutating operation that cannot prove them returns retained
ambiguity. Add a hook after initial bind/create and before each final proof so a
late hardlink demonstrably cannot report success (found 2026-09-01 during G5B1
candidate publication review).

<!-- applied-learning: line-oriented-native-protocols-must-reject-delimiter-bytes-at-both-boundaries -->
<a id="applied-learning-line-oriented-native-protocols-must-reject-delimiter-bytes-at-both-boundaries"></a>
**Line-oriented native protocols must reject delimiter bytes at both
boundaries.** Structured argv can safely carry a filename containing LF or CR,
but a newline-delimited result cannot represent that path without corrupting
field framing. Reject every protocol delimiter in the trusted-language
admission core and again in the native parser, and behaviorally test both a
read-only and mutating operation by bypassing the first boundary (found
2026-09-01 during G5B1 candidate publication review).

<!-- applied-learning: native-security-harnesses-must-compile-in-every-validation-guest -->
<a id="applied-learning-native-security-harnesses-must-compile-in-every-validation-guest"></a>
**Native security harnesses must compile in every authoritative validation
guest.** Host success does not prove a strict C harness is portable: transitive
system-header includes, libc syscall wrappers, utilities, and compiler warning
sets differ across macOS and Linux. Validate against the digest-pinned guest,
not a convenient local tag; include every standard declaration explicitly;
when musl omits `renameat2`, use the declared `SYS_renameat2` ABI and fail closed
on `ENOSYS`; avoid path construction rejected by `-Werror`; and compile both the
harness and production source with the guest's strict flags. Tests must use
image-owned portable fixtures rather than assuming Python or procps, and must
exercise the exact effective selected set rather than only the requested subset
(found 2026-09-01 when G5B1 passed on macOS but the authoritative Alpine guest
exposed harness, musl, and fixture assumptions).

<!-- applied-learning: pin-thread-counts-for-git-plumbing-inside-constrained-guests -->
<a id="applied-learning-pin-thread-counts-for-git-plumbing-inside-constrained-guests"></a>
**Pin thread counts for Git plumbing inside constrained guests.** Commands such
as `git pack-objects` may create worker threads even when Arbor invokes one
process. Under cap-drop or seccomp profiles this can fail with an opaque resource
error. Set both the Git config and command option explicitly (for example,
`-c pack.threads=1 pack-objects --threads=1`) and regression-test the actual argv
used by the contained path, not only its eventual output (found 2026-09-02 while
replaying the exact CrossApp validation candidate).

<!-- applied-learning: qualify-fresh-factories-through-actual-worker-startup-not-just-cli-discovery -->
<a id="applied-learning-qualify-fresh-factories-through-actual-worker-startup-not-just-cli-discovery"></a>
**Qualify fresh factories through actual worker startup, not just CLI discovery.**
A host with only Grok exposed stale ACP pool auto-detection that a multi-provider
laptop masked. CLI presence and OAuth success also did not prove Grok's Linux
sandbox could launch: bubblewrap was missing. Keep discovery tied to the provider
catalog, install native sandbox prerequisites, and observe a real ACP start before
calling the host ready. For provisioning, DHCP success is not internet admission:
upstream virtual-MAC allowlists need owner approval, not a NAT bypass. Rootless
Podman may additionally need the newly installed user dbus.socket started. Record
these separately from candidate validation or journey acceptance (2026-09-07).

<!-- applied-learning: provision-and-probe-through-the-same-pinned-container-installation -->
<a id="applied-learning-provision-and-probe-through-the-same-pinned-container-installation"></a>
**Provision and probe through the same pinned container installation.** The Apple container CLI is pinned at `/usr/local/bin/container` in `config/config.exs` and `Arbor.Shell.ExecutablePolicy`. Unsigned Homebrew builds are rejected. `:executable_not_found` can mean that pinned runtime is absent, not that Mix is absent inside a guest. Different installs can share a launchd label. Diagnose the executable and the install identity before changing a parser or a containment policy. Do not widen the path allowlist, and do not fall back to a host copy, to make a probe pass. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-09-27.)
