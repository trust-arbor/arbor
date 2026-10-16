# Applied Learning: Mix, Builds, Shell, and the Live Runtime

Read this when running Mix tasks or builds in worktrees, writing shell or Elixir one-liners, provisioning offline builds, or reloading and verifying the live runtime.

## Retained Applied Learning

<!-- applied-learning: in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries -->
<a id="applied-learning-in-elixir-map-literals-place-every-key-value-entry-before-keyword-style-atom-entries"></a>
**In Elixir map literals, place every `key => value` entry before keyword-style atom entries.** A map that starts with `foo: value` and later adds `dynamic_key => value` is a syntax error; either order all association entries first or use `Map.put/3` for dynamic keys (found 2026-07-14 during delegated Apple admission-core review).

<!-- applied-learning: for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella -->
<a id="applied-learning-for-local-diagnostic-mix-tasks-start-the-narrow-app-not-the-whole-umbrella"></a>
**Start only the runtime services a local Mix operation actually needs.** Compile or load paths without starting applications for module introspection; use the no-start run path when compiled code is sufficient. An operation calling an owning facade that needs processes must explicitly start its narrow application or supported minimal bootstrap rather than assuming compilation made the service available. Prefer the Shell direct-runtime boundary for offline Git operations that need only pinned executable policy and execution registration, and release its returned owned supervisor afterward. Do not start the whole umbrella merely to satisfy one local diagnostic, since that can launch endpoints, pollers, persistence owners, and unrelated hydration. Use live RPC when the intended subject is the running server's state. (Merged 2026-10-16 from 2 entries; first found 2026-07-07, last 2026-07-16.)

<!-- applied-learning: offline-git-operator-tasks-need-the-minimal-shell-direct-runtime -->
<a id="applied-learning-offline-git-operator-tasks-need-the-minimal-shell-direct-runtime"></a>
**Offline Git operator tasks need the minimal Shell direct runtime, not the Shell application.** Hardened `Arbor.Actions.Git` calls route through `Arbor.Shell.execute_direct/3`, so a no-start Mix task still needs the pinned executable policy and execution registry. Starting `:arbor_shell` is broader than it sounds: OTP also starts transitive application children (Signals, Security authority, skill indexing, container control planes), can emit startup logs into a machine-readable stdout stream, and performs unrelated initialization. Use `Arbor.Shell.start_direct_runtime/1`, stop the returned supervisor after the operation, and keep `:arbor_actions` stopped so a read-only branch audit cannot hydrate retention state or arm cleanup timers (found 2026-07-21 while running the historical branch migration dry run).

<!-- applied-learning: compile-an-edited-custom-mix-task-before-its-behavior-smoke-test -->
<a id="applied-learning-compile-an-edited-custom-mix-task-before-its-behavior-smoke-test"></a>
**Compile an edited custom Mix task before its behavior smoke test.** Mix can resolve and load the task module from the existing BEAM before project compilation updates that BEAM, so the first invocation after editing the task may compile the new source but still execute the prior module. Run `./bin/mix compile --warnings-as-errors`, then exercise the task in a fresh VM invocation before diagnosing the new source as ineffective (found 2026-07-21 while validating `arbor.coding.branches --output`).

<!-- applied-learning: avoid-escaped-map-key-syntax-inside-interpolated-mix-run-e-snippets -->
<a id="applied-learning-avoid-escaped-map-key-syntax-inside-interpolated-mix-run-e-snippets"></a>
**Avoid escaped map-key syntax inside interpolated `mix run -e` snippets.** An expression such as `"#{map[\"key\"]}"` passed through shell quoting is rejected by Elixir before the diagnostic runs. Bind the value with `Map.fetch!/2` first, then interpolate the bound variable (found 2026-07-10 while checking the live coding-plan action catalog).

<!-- applied-learning: run-focused-umbrella-tests-one-application-at-a-time-when-the-live-server-is-up -->
<a id="applied-learning-run-focused-umbrella-tests-one-application-at-a-time-when-the-live-server-is-up"></a>
**Run focused umbrella tests one application at a time when the live server is up.** Filesystem worktree isolation does not isolate fixed TCP ports: a root `mix test` command containing paths from multiple umbrella applications can start the full umbrella, collide with the running Gateway port, consume unbounded aggregate memory, and obscure the actual test result. Validators must invoke one app's test tree per fresh child BEAM under one shared monotonic deadline; use an isolated `MIX_BUILD_PATH`, while sharing only `MIX_DEPS_PATH` to avoid live-service collisions and compile-environment drift (found 2026-07-10 while verifying council lineage; production validator violation reproduced 2026-07-11 as exit 137 across 20 affected apps; port-isolation lesson reconfirmed 2026-07-15).

<!-- applied-learning: direct-mix-test-subprocesses-must-set-mix-env-test-explicitly -->
<a id="applied-learning-direct-mix-test-subprocesses-must-set-mix-env-test-explicitly"></a>
**Direct Mix test subprocesses must set `MIX_ENV=test` explicitly.** Project `cli.preferred_envs` can override Mix's usual test-task environment, especially in isolated validators that call the wrapper through `Port`. Default direct `["test" | args]` runs to test env, let an explicit caller environment win, and preserve both the head and failure tail in bounded compile feedback so setup noise cannot hide the actionable error (found 2026-07-11 during cross-app validation).

<!-- applied-learning: umbrella-runtime-config-must-not-execute-modules-from-an-optional-child-app -->
<a id="applied-learning-umbrella-runtime-config-must-not-execute-modules-from-an-optional-child-app"></a>
**Umbrella runtime config must not execute modules from an optional child app.** `config/runtime.exs` is evaluated when a lower-level child runs independently, so calling `Arbor.Agent.Config` there made `arbor_security` fail before its tests because `arbor_agent` was not compiled or loaded. Keep runtime config data-only; validate an app-specific environment selector inside that app's startup boundary, where the module and its dependencies are guaranteed to exist (found 2026-07-11 running the isolated Security suite).
A `mix run --no-start` inspection still evaluates runtime config. For compiled-code
introspection in an isolated leaf, isolate its operator-state home and relevant
external config selectors instead of starting unrelated apps to satisfy a
host-specific loader. Check the pinned Mix parser before assuming a flag can
skip runtime config (reinforced 2026-09-27 during native source inspection).

<!-- applied-learning: compile-env-reads-must-target-the-exact-runtime-invariant -->
<a id="applied-learning-compile-env-reads-must-target-the-exact-runtime-invariant"></a>
**Compile-time config reads must target the exact invariant, not a runtime-overridable parent.** `Application.compile_env(app, Module)` records the whole keyword list; changing a sibling runtime value such as an endpoint port then fails Mix's compile-env validation even when the compile-time `:code_reloader` flag is unchanged. Use a nested path such as `[Module, :code_reloader]` with an explicit default whenever sibling values are configured in `runtime.exs` (found 2026-08-25 when `arbor.recompile` rejected a dashboard port override whose only semantic difference was keyword order).

<!-- applied-learning: distribution-readiness-is-not-application-readiness -->
<a id="applied-learning-distribution-readiness-is-not-application-readiness"></a>
**Verify the next operation's prerequisites beyond transport reachability.** Use separately bounded distribution and application startup phases, then positively check required owners, public interfaces, durable stores, budget configuration, SQL schema, credentials, and recipient state before handoff or effects. Managed startup checks applications, but healthy HTTP or a connected transport alone cannot prove feature readiness. After an initial ping, application-readiness nodedown must fail promptly while preserving launch tracking; it does not prove OS process death or authorize cleanup, stop, or restart. Partial startup and RPC timeout retain their existing bounded budget. Match service-manager observations to the canonical job's executable, arguments, and PID, parsing fields at the owning level rather than nested metadata. Require fresh connectivity and semantic success receipts for follow-up commands. Repair only reviewed missing migrations and retain partial outcomes. After authentication and current authorization, refuse new commands to stopped agents before durable admission while preserving exact saved-command replay and later uncertainty. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-16.)

<!-- applied-learning: authenticate-the-control-plane-service-not-only-its-cli -->
<a id="applied-learning-authenticate-the-control-plane-service-not-only-its-cli"></a>
**Authenticate the control-plane service, not only its CLI.** Apple Container's signed CLI writes a user-owned LaunchAgent for `container-apiserver`, while user configuration can select the VM kernel and vminit image. A containment backend must bind launchd's running program/argv to a separately pinned signed API-server binary and explicitly select root/operator-owned kernel, immutable init image, platform, and runtime values; self-reported health JSON is corroboration, not authority (found 2026-07-14 auditing Apple Container 1.1.0 before the imperative prober).

<!-- applied-learning: escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration -->
<a id="applied-learning-escape-backticks-inside-javascript-template-literals-used-for-tool-orchestration"></a>
**Escape JavaScript transport-string delimiters before tool dispatch.** A Markdown backtick embedded unescaped in a JavaScript template literal terminates the transport string while the orchestration program is being parsed. The failure occurs before the tool call, so do not infer that a delegated task was created from its proximity to dispatch code. Build prompts as ordinary quoted lines joined with a newline, use plain text, or correctly escape every embedded template delimiter. Keep JavaScript string construction separate from shell command quoting: escaping a template delimiter does not make shell interpolation safe. Verify that dispatch returned an actual task identity before treating the operation as started. (Merged 2026-10-16 from 2 entries; first found 2026-07-14, last 2026-07-16.)

<!-- applied-learning: beam-monotonic-timestamps-may-be-negative -->
<a id="applied-learning-beam-monotonic-timestamps-may-be-negative"></a>
**BEAM monotonic timestamps may be negative.** `System.monotonic_time/1` uses an arbitrary origin; only differences and ordering are meaningful. Validate that samples are integers, not non-negative integers, and compute deadlines/durations by subtraction (`deadline - now`) so a perfectly healthy production clock is not rejected (confirmed 2026-07-15: the live node's millisecond sample was negative while reviewing the Apple executor).

<!-- applied-learning: do-not-redefine-built-in-elixir-typespec-names -->
<a id="applied-learning-do-not-redefine-built-in-elixir-typespec-names"></a>
**Do not redefine built-in Elixir typespec names.** Names such as `timeout` are built in and a local `@type timeout` can fail compilation on the pinned toolchain. Use a domain-specific name such as `deadline_ms` or reference the built-in type directly (found 2026-07-16 reviewing the benchmark Git deadline helper).

<!-- applied-learning: relocating-only-mix-exs-does-not-relocate-an-umbrella-project-coherently -->
<a id="applied-learning-relocating-only-mix-exs-does-not-relocate-an-umbrella-project-coherently"></a>
**Relocating only `MIX_EXS` does not relocate an umbrella project coherently.** Relative `apps_path`, lockfile, config, build, and dependency paths still resolve from the process/project context, while symlink facades can create divergent lexical roots. Keep the normal umbrella-root CWD or make every project path consistently absolute through one shared helper (found 2026-07-16 validating contained Mix execution).

<!-- applied-learning: avoid-brew-cat-for-read-only-formula-inspection -->
<a id="applied-learning-avoid-brew-cat-for-read-only-formula-inspection"></a>
**Avoid `brew cat` for read-only formula inspection.** It can enable Homebrew developer mode as a side effect; inspect the installed formula path directly when possible, and run `brew developer off` after an accidental enablement (found 2026-07-16 comparing Homebrew and standalone Apple Container installations).

<!-- applied-learning: a-mix-task-s-compile-claim-needs-an-explicit-compile-requirement -->
<a id="applied-learning-a-mix-task-s-compile-claim-needs-an-explicit-compile-requirement"></a>
**A Mix task's compile claim needs an explicit compile requirement.** `arbor.recompile` documented that Mix compiled local source first, but without `@requirements ["compile"]` it compared the running VM only with the stale on-disk BEAM and truthfully reported every module unchanged. When a task consumes fresh build artifacts, declare the requirement and regression-test the task metadata; verify the reload behaviorally rather than trusting a zero-failure summary (found 2026-07-17 while loading the review-decision projection fix).

<!-- applied-learning: when-changing-every-mix-exs-shape-exercise-static-consumers-of-mix-project-source -->
<a id="applied-learning-when-changing-every-mix-exs-shape-exercise-static-consumers-of-mix-project-source"></a>
**When changing every `mix.exs` shape, exercise static consumers of Mix-project source.** Moving `project/0` from a direct keyword-list body to `paths = ...` followed by that list kept Mix behavior correct but made the fail-closed cross-app AST parser reject every app as `:dynamic_or_malformed_project`. A static parser can safely follow Elixir block return semantics and inspect the final expression while still rejecting a variable or call as the returned project metadata; include that source shape in parser regressions before relying on live validation (found 2026-07-16 during Phase 6 cross-app dogfood).

<!-- applied-learning: mix-arbor-rpc-accepts-one-positional-elixir-expression-and-no-timeout-flag -->
<a id="applied-learning-mix-arbor-rpc-accepts-one-positional-elixir-expression-and-no-timeout-flag"></a>
**`mix arbor.rpc` accepts one positional Elixir expression and no timeout flag.** When a shell wrapper constructs the call, keep the expression itself on one physical argument line and encode any message newlines inside its Elixir string; passing a JSON-escaped multiline expression can deliver literal `\\n` tokens outside a string and fail parsing before RPC. Use the task API's own bounded operations rather than inventing `--timeout` for this Mix task (found 2026-07-18 steering `task_188034`).

<!-- applied-learning: elixir-is-list-1-recognizes-cons-cells-including-improper-lists -->
<a id="applied-learning-elixir-is-list-1-recognizes-cons-cells-including-improper-lists"></a>
**Elixir `is_list/1` recognizes cons cells, including improper lists.** For `[a, b | tail]`, `is_list/1` is true for the outer list and for the remaining `[b | tail]`; it becomes false only at the final non-list tail. Do not infer that an improper spine bypasses a guarded recursive list walker. Reproduce the exact term in IEx/Tidewave before changing security traversal logic; bound each visited head and explicitly handle the final tail (verified 2026-07-19 while reviewing `LogRedactor`).

<!-- applied-learning: retain-compiled-beam-binaries-when-loading-exs-diagnostic-modules-remotely -->
<a id="applied-learning-retain-compiled-beam-binaries-when-loading-exs-diagnostic-modules-remotely"></a>
**Retain compiled BEAM binaries when loading `.exs` diagnostic modules remotely.** A
module defined directly in an `.exs` launcher may return `:error` from
`:code.get_object_code/1`, even immediately after compilation, so a helper that recompiles
locally and then asks the code server for bytes cannot be transferred to a running node.
Keep the `{module, beam_binary}` tuple returned by `Code.compile_quoted/1` or
`Code.compile_string/1` and pass that exact binary to `:code.load_binary/3` on the target
node (found 2026-07-20 while launching the Phase 6 r10 benchmark).

<!-- applied-learning: serialize-mix-commands-within-each-worktree -->
<a id="applied-learning-serialize-mix-commands-within-each-worktree"></a>
**Serialize Mix operations sharing execution resources and candidate ownership.** A worktree isolates source paths, but commands within it still share build outputs, dependency compilation, protocol consolidation, and runtime resources. Run focused suites sequentially; parallel execution requires independently owned worktrees, build roots, and runtime paths. Respect an active validator's exclusive ownership of retained candidate bytes: manager-side tests can invalidate an attested fingerprint even with a separate build path if scratch files appear beneath the application. Verify from another worktree or wait for the task to become terminal. Put regression scratch in an exclusive cryptorandom directory under the system temporary root, register cleanup, and satisfy the tracked-test guard against literal ExUnit tmp-dir tags across the existing corpus. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-07-20.)

<!-- applied-learning: format-only-scoped-paths-in-an-inherited-or-dirty-worktree -->
<a id="applied-learning-format-only-scoped-paths-in-an-inherited-or-dirty-worktree"></a>
**Constrain formatting to validated owned paths and account for build effects.** Build formatter arguments from the actual ownership-manifest schema and require a nonempty list of existing owned files before invoking Mix; an empty argument list can silently format the project. Inspect source diffs before staging and remove incidental unrelated rewrites from narrow changes. Explicit filenames limit source formatting, but plugins can load paths and compile dependencies across the umbrella. Prepare formatting in an isolated image and compare build-artifact inventories as well as source deltas. Preserve failed compilation or qualification evidence, independently bind and review rebuilt outputs, and reject unexpected artifact changes. Never restore stale attested bytes or reclassify changed BEAMs as disposable caches to make evidence pass. Keep formatting's file-existence precondition separate from predecessor compilation, where new candidate files may legitimately be absent. (Merged 2026-10-16 from 2 entries; first found 2026-07-17, last 2026-07-20.)

<!-- applied-learning: never-mutate-a-live-retention-journal-from-a-second-beam -->
<a id="applied-learning-never-mutate-a-live-retention-journal-from-a-second-beam"></a>
**Never mutate a live workspace-retention journal from a second BEAM.** The durable store intentionally enforces a single-writer inventory snapshot while the lease registry holds corresponding hot state. Offline cleanup that shares `ARBOR_HOME` can delete markers out of band, poison the store with `snapshot_mismatch`, and leave the registry stale. Use the live owner APIs; if reconciliation is required, first prove there are no active leases, repair the durable inventory, then restart both supervised store and registry so they rehydrate the same snapshot. Do not weaken drift detection to mask split ownership (found 2026-07-21 after out-of-band retained-workspace cleanup blocked subsequent coding-task acquisition).

<!-- applied-learning: parenthesize-do-block-expressions-assigned-to-module-attributes -->
<a id="applied-learning-parenthesize-do-block-expressions-assigned-to-module-attributes"></a>
**Parenthesize do-block expressions assigned to module attributes.** In Elixir,
`@items for ... do ... end` binds the block to the module-attribute macro and
raises instead of assigning the comprehension. Use `@items (for ... do ...
end)` or an `Enum` pipeline expression; compile the touched module before
treating formatter success as syntax validation (found 2026-07-28 while adding
the executable coding-profile declaration guard).

<!-- applied-learning: zsh-command-substitution-does-not-split-newline-path-lists -->
<a id="applied-learning-zsh-command-substitution-does-not-split-newline-path-lists"></a>
**Zsh command substitution does not split newline path lists by default.**
Passing `$(git diff --name-only ...)` to a formatter can produce one
newline-containing argument instead of one argument per path. Use a native Zsh
array expansion such as `${(@f)...}` for trusted line-delimited paths, or a
NUL-delimited producer and consumer for arbitrary filenames, then verify the
tool actually inspected the intended file count (found 2026-07-28 during the
Phase F scoped formatting check).

<!-- applied-learning: isolate-mix-build-roots-by-revision-and-environment -->
<a id="applied-learning-isolate-mix-build-roots-by-revision-and-environment"></a>
**Give each source revision and Mix environment its own build root.** An explicit MIX_BUILD_PATH names the exact artifact directory and bypasses ordinary environment partitioning, so sharing it across baseline/candidate or dev/test can execute stale BEAMs or remove required support artifacts. Require an explicit MIX_ENV for overridden build roots and derive a distinct environment directory beneath each revision-owned root. Compile in the intended execution environment before any no-compile run; a default-environment compile does not refresh test artifacts. Keep comparison builds separate from the live server's build tree, and serialize any remaining operations that share dependency or runtime resources. (Merged 2026-10-16 from 2 entries; first found 2026-07-21, last 2026-07-30.)

<!-- applied-learning: managed-lifecycle-commands-must-bind-to-the-persisted-running-node-identity -->
<a id="applied-learning-managed-lifecycle-commands-must-bind-to-the-persisted-running-node-identity"></a>
**Managed lifecycle commands must bind to the persisted running-node identity.**
Re-detecting the host on every invocation can make restart look for
`arbor_dev@new-host` while `arbor_dev@old-host` is still alive, skip shutdown,
overwrite PID metadata, and collide in EPMD. Persist the exact node name and
host with the PID at successful start; prefer an explicit operator override
only when intentionally relocating; use the stored identity for status, stop,
and restart; and refuse to start when a verified managed PID is alive but
unreachable. Regression-test host drift and stale or mismatched metadata (found
2026-08-02 restarting after Linux dependency-baseline activation).

<!-- applied-learning: isolated-validation-artifacts-need-owned-disk-admission-and-garbage-collection -->
<a id="applied-learning-isolated-validation-artifacts-need-owned-disk-admission-and-garbage-collection"></a>
**Isolated validation artifacts need owned disk admission and garbage
collection.** Check free bytes and inodes before admitting worker or validation
work, attach exact owner and attempt identity plus expiry to every artifact, and
clean only resources whose ownership and terminal state are proven. Treat
`ENOSPC` as an infrastructure failure that preserves the candidate; never delete
temporary paths by broad prefix and age alone (found 2026-08-02 after lifecycle
validation exhausted the host disk).

<!-- applied-learning: do-not-launch-long-lived-services-from-disposable-validation-build-roots -->
<a id="applied-learning-do-not-launch-long-lived-services-from-disposable-validation-build-roots"></a>
**Do not launch long-lived services from disposable validation build roots.**
An isolated `MIX_BUILD_ROOT` supplied to a lifecycle command can be inherited by
the background daemon, leaving the service dependent on a temporary path that a
later cleanup may reclaim. Use isolated roots for compile and test evidence, but
perform the final managed restart from a stable project build environment unless
the daemon boundary explicitly sanitizes transient build variables (found
2026-08-02 while verifying managed lifecycle identity).

<!-- applied-learning: portable-file-mode-probes-must-try-gnu-stat-before-bsd-stat -->
<a id="applied-learning-portable-file-mode-probes-must-try-gnu-stat-before-bsd-stat"></a>
**Portable file-mode probes must try GNU `stat` before BSD `stat`.** GNU
`stat -f` succeeds but prints filesystem details, so a BSD-first `||` chain
never reaches its GNU fallback in Linux containers and can falsely fail a
permission test. Use `stat -c '%a' file 2>/dev/null || stat -f '%Lp' file
2>/dev/null`, then validate the output shape (found 2026-08-02 when cross-app
validation falsely rejected the unrelated VP-04A candidate).

<!-- applied-learning: callback-validation-must-not-depend-on-incidental-module-preload -->
<a id="applied-learning-callback-validation-must-not-depend-on-incidental-module-preload"></a>
**Callback validation must not depend on incidental module preload.**
`function_exported?/3` returns false for a compiled but unloaded module, so a
focused test or first production call can reject a valid injectable adapter
while a full suite passes because another test loaded it. At an owned adapter
boundary, load and inspect exports deterministically (for example with a
catch-safe `module.module_info(:exports)`) before validating callbacks; prove
the behavior from an explicitly unloaded compiled module instead of preloading
it in the test (found 2026-08-03 while isolating VP-04D2B Session startup).
`Kernel.ParallelCompiler.compile_to_path/3` can emit a BEAM without loading its
module (2026-10-05). In a fresh no-start compiler probe, condition purge/delete
on `:code.is_loaded/1`, then explicitly load the emitted disk file. Verify its
actual `:code.which/1` path, compile-source path and loaded/on-disk code MD5
before accepting the artifact; a successful write does not prove loaded identity.

<!-- applied-learning: elixir-typespecs-cannot-express-singleton-binary-map-keys -->
<a id="applied-learning-elixir-typespecs-cannot-express-singleton-binary-map-keys"></a>
**Elixir typespecs cannot express singleton binary map keys.** Both
`%{"provider" => String.t()}` and `%{required("provider") => String.t()}` are
rejected as unexpected expressions in Elixir 1.19. When runtime data
deliberately uses exact string keys, keep a compilable generic string-key map
type and document the closed runtime shape in `@typedoc`; do not "fix" one
invalid literal-key form by switching to the other (found 2026-08-03 during
VP-05D1 validation rework).

<!-- applied-learning: in-zsh-harness-scripts-never-use-status-as-a-scratch-variable -->
<a id="applied-learning-in-zsh-harness-scripts-never-use-status-as-a-scratch-variable"></a>
**Capture shell exits in an ordinary scalar with cleanup already installed.** In zsh, status is a read-only special parameter; assigning status from the preceding exit code aborts the wrapper and can hide the command's real result or skip cleanup. Capture the exit immediately in a task-specific scalar such as exit_code or rc before any intervening command changes it. Install the EXIT cleanup trap before allocating worktrees, build roots, or other owned resources, and make it run on both success and failure. Preserve the primary command failure if cleanup also fails so the wrapper reports the actual validation outcome. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-08-20.)

<!-- applied-learning: hot-reload-updates-modules-not-running-child-processes -->
<a id="applied-learning-hot-reload-updates-modules-not-running-child-processes"></a>
**Converge loaded code, live state, and supervised ownership before dispatch.** Use the supported recompile path between tasks; avoid raw umbrella recompilation. Code loading neither migrates GenServer state nor replaces retained local function captures, startup arguments, or supervision topology. Check existing state and required owners, then apply an explicit migration or compatible access; restart the smallest owner only after work quiesces and persisted reconstruction is safe. Represent retained callbacks as reload-stable data or references. Loaded/disk digest agreement alone proves neither process readiness nor reconstruction safety. Bind state-validity certificates to the loaded identity of every module whose semantics the validator executes, recompute that bounded identity at the callback gate, and fail closed when unavailable; do not cache it across independently reloadable modules. Verify fresh catalog identities, exact child ownership, and public readiness after reload or managed restart. For stop/build/start deployment, stop the owning daemon before source integration can trigger automatic reload, keep it stopped through the build, and verify the new owner before dispatch. (Merged 2026-10-16 from 6 entries; first found 2026-07-10, last 2026-08-26.)

<!-- applied-learning: load-modules-before-installing-erlang-call-trace-patterns -->
<a id="applied-learning-load-modules-before-installing-erlang-call-trace-patterns"></a>
**Load modules before installing Erlang call trace patterns.**
`:erlang.trace_pattern/3` returns zero for an unloaded module and does not
retroactively attach when the module loads later. A call-tracing test must
`Code.ensure_loaded!/1` each target before installing patterns, and it must
drain trace delivery before terminating the tracer. Otherwise randomized test
order can make a security regression pass or fail according to which module an
earlier test happened to load (found 2026-08-23 during P1A-1 cross-app
validation).

<!-- applied-learning: in-zsh-harness-scripts-never-use-path-as-a-scalar-variable -->
<a id="applied-learning-in-zsh-harness-scripts-never-use-path-as-a-scalar-variable"></a>
**Use task-specific variable names for filesystem paths in zsh.** The lowercase path parameter is the special array tied to PATH. Assigning a scalar or loop value to it changes executable lookup for the rest of the shell and can make installed tools appear unavailable. Name filesystem values worktree_path, repo_path, or another task-specific scalar, including in short diagnostic one-liners and cleanup loops. Review variable assignments before diagnosing command-not-found output as a missing installation: an earlier loop iteration may have replaced the search path. Preserve the caller's environment when constructing harness commands. (Merged 2026-10-16 from 4 entries; first found 2026-07-15, last 2026-08-26.)

<!-- applied-learning: sources-only-validation-compiles-need-git-and-a-normal-mix-compile -->
<a id="applied-learning-sources-only-validation-compiles-need-git-and-a-normal-mix-compile"></a>
**Sources-only validation compiles need Git and a normal Mix compile.** When dependency sources are populated but the build directory is empty, run ordinary `mix compile`, optionally with `--warnings-as-errors`. Supply Git in the validation image and retain dependency checkout metadata so lock inspection can succeed. `--no-deps-check` skips the dependency loading/compilation needed to make dependency-provided compilers available. Later xref/test children may use it after the build is populated. Do not omit in-unit dependency compilation unless the precompiled test baseline is digest-pinned. Keep provisioning separate from no-network validation. (Trimmed 2026-10-16; first found 2026-08-26.)

<!-- applied-learning: measure-network-exceptions-at-their-actual-socket-boundary -->
<a id="applied-learning-measure-network-exceptions-at-their-actual-socket-boundary"></a>
**Measure network exceptions at the actual socket boundary.** Qualify local locking with real loopback bind, connect and closure while retaining remote-download denial and Mix locking. Probe wildcard binds, non-loopback inbound traffic and non-loopback outbound denial separately; a localhost selector does not establish exclusive loopback confinement. Bind the actual listener to its reviewed loopback source. Check the installed sandbox parser and do not invent per-host SBPL admission. A reviewed remote TCP 443 exception is port-only unless separate evidence establishes hostname filtering; retain ordinary TLS hostname verification and enforcing capability/egress gates. Report only observed permissions, without inferring provider or device acceptance. When a denied transport syscall breaks delivery, use supported transport configuration while retaining outbound denial and verify exact served bytes. Preserve failed diagnostics. (Extracted 2026-10-16 from sources-only-validation-compiles-need-git-and-a-normal-mix-compile; first found 2026-10-04.)

<!-- applied-learning: provision-exact-offline-dependency-resolution-inputs -->
<a id="applied-learning-provision-exact-offline-dependency-resolution-inputs"></a>
**Provision exact locked inputs for offline dependency resolution.** Resolve umbrella dependency changes from the root and compare every lock record. Retain only resolver-generated records for admitted changes, preserve unrelated records, and require full-root `deps.get --check-locked` without further lock changes. Select the resolution environment explicitly with `--only`; a DEV-only build does not qualify tests. Provision reviewed dependency code, licenses and checksum-bound public registry metadata into the private execution root; never copy account configuration or enable networking to hide missing inputs. Compare registry requirements with original package metadata rather than normalized lock requirement text. Retain exact checksum, version, dependency identity, repository and optionality checks, then let ordinary locked resolution decide constraint acceptance. Admit omitted or empty-map dependency metadata only when both registry and lock prove no dependencies. Treat the frozen cache snapshot as input. Separate source overlays from locked assets, assemble fresh trees, and verify actual compiled source paths after explicitly rebuilding changed dependencies. Preserve source and native guards. (Extracted 2026-10-16 from sources-only-validation-compiles-need-git-and-a-normal-mix-compile; first found 2026-09-27.)

<!-- applied-learning: mix-listeners-are-required-for-safe-phoenix-reloads-in-long-lived-dev-runtimes -->
<a id="applied-learning-mix-listeners-are-required-for-safe-phoenix-reloads-in-long-lived-dev-runtimes"></a>
**Register `Phoenix.CodeReloader` as a Mix listener in long-lived dev runtimes.** Tidewave calls `Phoenix.CodeReloader.reload/2` before each live eval even when the endpoint plug's `code_reloader` config is false. Without root `listeners: [Phoenix.CodeReloader]`, externally compiled umbrella apps take Phoenix's fallback `:code.purge/1` path, which can kill durable factory processes still referencing old code and surface only `:task_owner_died`. Keep the listener in the umbrella `mix.exs`; after adding it, restart the server before trusting live eval (found 2026-08-27 during P1B-2A validation).

<!-- applied-learning: preserve-the-formatter-api-s-newline-contract -->
<a id="applied-learning-preserve-the-formatter-api-s-newline-contract"></a>
**Preserve the formatter API's newline contract.** `Code.format_file!/2` already includes the file's terminating newline; appending another creates blank-at-EOF churn. If formatting without Mix in an isolated source review, write its iodata directly, or normalize to exactly one final newline, then verify the exact files with the repository formatter (found 2026-09-09 during private-turn memory containment validation).
For a read-only check, compare the complete source to the formatter's complete
iodata output; trimming only the source incorrectly reports a mismatch and can
trigger that same extra-newline churn (2026-10-05 OAuth codec qualification).
Wait for the entire formatting/check process to finish with exit zero before
writing dependent success metadata. Compare parsed ASTs after removing metadata
and normalizing plain `~w` whitespace by word semantics; valid formatting can
change `Macro.to_string/1` rendering. Then compare exact final formatter bytes.
On 2026-10-05, the first pass exited 1 and its unadmitted metadata was corrected
to incomplete; the later complete five-file format and normalized parse
comparison passed.

<!-- applied-learning: remember-that-the-elixir-pipe-inserts-the-first-argument -->
<a id="applied-learning-remember-that-the-elixir-pipe-inserts-the-first-argument"></a>
**Remember that the Elixir pipe inserts the first argument.** This applies to
Erlang modules too: `value |> :crypto.hash(:sha256)` calls
`:crypto.hash(value, :sha256)`, while the intended call is
`:crypto.hash(:sha256, value)`. Prefer an explicit call whenever the data
argument is not first; both terms can satisfy loose runtime types, so parsing
alone will not catch the reversal (found 2026-10-07 while reviewing a durable
capability rollback regression).

<!-- applied-learning: isolate-the-git-index-for-snapshot-checks -->
<a id="applied-learning-isolate-the-git-index-for-snapshot-checks"></a>
**Isolate the Git index for snapshot checks.** An rsynced copy may retain a
`.git` file that points at the live worktree index; `git add` in that copy then
stages the real worktree. Yet `git ls-files` checks omit new candidate files
unless the index includes them. Inspect the snapshot's Git metadata first. For
index-aware checks, set `GIT_INDEX_FILE` to a temporary copy of the live index,
stage the candidate against that private index, and leave the live index alone
(found 2026-10-07 while running umbrella fast tests for security review
remediation).
