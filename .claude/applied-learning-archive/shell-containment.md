# Applied Learning archive: shell-containment

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: killing-a-port-owner-does-not-prove-its-descendants-stopped -->
<a id="applied-learning-killing-a-port-owner-does-not-prove-its-descendants-stopped"></a>
**Killing a Port owner does not prove its descendants stopped.** Timeout, cancellation, or output-limit code that sends SIGKILL only to the immediate OS PID can return while Git hooks, Mix children, helpers, or detached subprocesses continue side effects. Launch untrusted external work in an owned process group/container, terminate the whole group on every terminal path, await verified group exhaustion, and regress with delayed descendant markers (found 2026-07-11 reviewing the direct-argv shell correction).

<!-- applied-learning: prove-descendant-requirements-per-exact-cli-subcommand-before-expanding-fork-authority -->
<a id="applied-learning-prove-descendant-requirements-per-exact-cli-subcommand-before-expanding-fork-authority"></a>
**Prove descendant requirements per exact CLI subcommand before expanding fork authority.** Apple `container system status` fails under the generic no-fork runner, but the exact reviewed `list`, corrected `create`, and `start --attach` argv all succeeded through that same generic runner. A shared executable does not imply shared process behavior; reproduce the exact command before adding another fork-permitting launcher mode (found 2026-07-16 during the Slice 2D live matrix).

<!-- applied-learning: single-quote-shell-search-patterns-that-contain-backticks -->
<a id="applied-learning-single-quote-shell-search-patterns-that-contain-backticks"></a>
**Single-quote shell search patterns that contain backticks.** Backticks still perform command substitution inside double quotes, including in an `rg` pattern. Use single quotes or escape each backtick so a diagnostic search cannot execute fragments from the pattern (found 2026-07-14 while auditing Apple Container source references).

<!-- applied-learning: a-raw-elixir-sigil-does-not-escape-the-outer-shell-quote -->
<a id="applied-learning-a-raw-elixir-sigil-does-not-escape-the-outer-shell-quote"></a>
**A raw Elixir sigil does not escape the outer shell quote.** When the whole `arbor.rpc` expression is enclosed in shell single quotes, an apostrophe anywhere inside the `~S|...|` message still terminates the shell argument before Elixir sees it. Either keep the message apostrophe-free, or construct the argv without a shell-quoted expression; raw sigils solve Elixir quoting only (found 2026-07-18 steering the security-regression test-seam follow-up).

<!-- applied-learning: exact-security-inventories-should-be-batched-before-expensive-contained-execution -->
<a id="applied-learning-exact-security-inventories-should-be-batched-before-expensive-contained-execution"></a>
**Exact security inventories should be batched before expensive contained execution.** Git tracked/untracked enumeration plus segment/path/lstat verification is the authorization boundary; one container per verified file is merely an execution strategy and can make a bounded stage structurally impossible. Preserve the exact verified argv entries, then partition them by closed file-count and argument-byte limits so each child remains bounded while container startup is amortized (found 2026-07-17 when per-file Apple Container lifecycle overhead exhausted a 20-minute stage after only a small fraction of 511 files).

<!-- applied-learning: a-command-name-policy-cannot-enforce-an-argument-sensitive-shell-safety-floor -->
<a id="applied-learning-a-command-name-policy-cannot-enforce-an-argument-sensitive-shell-safety-floor"></a>
**A command-name policy cannot enforce an argument-sensitive shell safety floor.** The pinned Bash `CommandPolicy` callback receives only command name and category, so it cannot see opaque payloads such as `sh -c`, `find -exec`, or `awk system(...)`, nor Arbor's dangerous flags. Do not claim capability-safe compound execution from that callback alone: add an argv-aware runtime gate or reject interpreter/wrapper and dynamically constructed forms fail closed, and keep the feature disabled while that boundary is incomplete (found 2026-07-11 reviewing CapShell resource-bound dogfood).

<!-- applied-learning: propagate-nested-readiness-deadlines-to-spawn-capable-probes -->
<a id="applied-learning-propagate-nested-readiness-deadlines-to-spawn-capable-probes"></a>
**Propagate nested readiness deadlines to spawn-capable probes.** A readiness
callback cannot safely invoke a probe with a 300-second default underneath a
20-second callback and 30-second transport. Give the full probe an explicit
readiness-owned subdeadline, leave bounded headroom for the enclosing
projection, and keep the transport strictly larger so each layer returns its
own timeout and contains its children (found 2026-08-28 when full Apple
Container admission took 26 seconds and coding readiness killed it at 20 and
then 25 seconds).

<!-- applied-learning: a-declared-workflow-profile-is-not-executable-until-every-claimed-invariant-is-mechanically-enforced -->
<a id="applied-learning-a-declared-workflow-profile-is-not-executable-until-every-claimed-invariant-is-mechanically-enforced"></a>
**A declared workflow profile is not executable until every claimed invariant is mechanically enforced.** Running a selected `_test.exs` file against the candidate does not prove a security regression fails against the base revision and passes against the candidate. Keep the profile discoverable but fail closed with a precise missing-primitive reason until both sides of the claim are enforced (found 2026-07-10 reviewing the initial `security_regression` compiler profile).

<!-- applied-learning: contained-mix-executable-not-found-can-mean-the-pinned-container-runtime-not-mix -->
<a id="applied-learning-contained-mix-executable-not-found-can-mean-the-pinned-container-runtime-not-mix"></a>
**Contained Mix `:executable_not_found` can mean the pinned container runtime, not Mix.** `Arbor.Actions.Mix` already resolves the reviewed repository wrapper, but spawn containment separately requires the Apple-signed `container` CLI at the fixed `/usr/local/bin/container` authority path. An unsigned Homebrew binary at `/opt/homebrew/bin/container` is intentionally rejected; do not widen the path policy or fall back to host execution merely to make validation pass. Inspect `validate/status.json` and verify code signing/runtime installation before debugging the wrapper (confirmed 2026-07-15 after both coding-fix delegations reached validation).

<!-- applied-learning: verify-static-runtime-api-claims-against-the-pinned-toolchain-when-executable-evidence-disagrees -->
<a id="applied-learning-verify-static-runtime-api-claims-against-the-pinned-toolchain-when-executable-evidence-disagrees"></a>
**Verify static runtime API claims against the pinned toolchain when executable evidence disagrees.** Documentation or memory about an Erlang option can be stale across OTP releases; if a public behavioral test succeeds on the repository's pinned runtime, reproduce the disputed call directly there before redesigning around an assumed incompatibility. Treat the observed pinned behavior as evidence while still checking portability deliberately (found 2026-07-11 reviewing `:file.open` mode handling in eval persistence).

<!-- applied-learning: the-working-grok-no-shell-boundary-is-an-attested-arbor-owned-profile -->
<a id="applied-learning-the-working-grok-no-shell-boundary-is-an-attested-arbor-owned-profile"></a>
**The working Grok no-shell boundary is an attested Arbor-owned profile.** Stage a private `0600` `--agent-profile` with exact bytes, path, type, and mode attested at launch and reconnect; expose native file tools while disallowing `run_terminal_cmd`, `task`, `get_task_output`, and `kill_task`. The proof must be capability-backed and include both a denied terminal marker and a successful native edit (found 2026-07-19 during Grok ACP containment work).

<!-- applied-learning: do-not-print-full-process-command-lines-during-diagnostics -->
<a id="applied-learning-do-not-print-full-process-command-lines-during-diagnostics"></a>
**Do not print full process command lines during diagnostics.** Provider CLIs,
BEAM launchers, and wrapper processes can carry credentials or signed material
in argv. Inspect bounded fields such as PID, elapsed time, executable name
(`comm`), working directory, and task telemetry instead of `ps ... command`;
redact any unavoidable argv evidence before it reaches logs or conversation
output (found 2026-07-28 while checking whether delegated validation was still
active).

<!-- applied-learning: prime-apple-container-s-builder-explicitly-on-first-use -->
<a id="applied-learning-prime-apple-container-s-builder-explicitly-on-first-use"></a>
**Prime Apple Container's builder explicitly on first use.** Inspect `container system property list`, pull the configured builder image with bounded download concurrency, then run `container builder start` before the first build. Otherwise the automatic pull/start path can look like a missing BuildKit runtime or a hung build (found 2026-07-16 provisioning the standalone Apple Container 1.1.0 runtime).
Record the builder's running/stopped state and creation identity before a build,
not just its name. A build can recreate and start a previously stopped instance;
the pre-existing name does not make that newly running instance unrelated to the
task. Restore only the task's change after the build and verify the resulting
inventory (found 2026-09-27 during native Git baseline renewal).

<!-- applied-learning: safepath-resolve-within-2-is-lexical-containment-not-an-existing-file-authorization-result -->
<a id="applied-learning-safepath-resolve-within-2-is-lexical-containment-not-an-existing-file-authorization-result"></a>
**`SafePath.resolve_within/2` is lexical containment, not an existing-file authorization result.** It normalizes `..` but does not return a symlink-resolved target. Before reading a user-selected existing file, resolve and compare the real workdir and real target, authorize the caller-visible path through the fs/FileGuard gate, and read the proven canonical target; otherwise an in-workdir symlink can redirect a read outside the workspace (found 2026-07-10 reviewing Grok's pipeline `source_file` authorization fix).

<!-- applied-learning: schema-bounded-mix-actions-must-stay-within-the-basic-shell-sandbox-s-allowed-flag-set -->
<a id="applied-learning-schema-bounded-mix-actions-must-stay-within-the-basic-shell-sandbox-s-allowed-flag-set"></a>
**Schema-bounded Mix actions must stay within the basic shell sandbox's allowed flag set.** `Mix.Compile` cannot expose `--force` while it runs through `Shell.execute(..., sandbox: :basic)`: the sandbox rejects that flag before Mix starts. Add flags only after checking the sandbox policy or moving the action to a non-shell argv execution path (found 2026-07-09 while routing coding-agent validation through `arbor://action/mix/compile`).
