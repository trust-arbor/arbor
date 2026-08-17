# Safe Shell — Implementation Audit

**Date:** 2026-08-10
**Scope:** `apps/arbor_shell` (~38.5k LOC Elixir + 43 KB C launcher) plus every safe-shell-adjacent site in the umbrella and the sibling `jido_sandbox` project.
**Method:** Full read of the core policy/execution path, the C launcher, the Apple Container subsystem, the Linux dependency baseline subsystem, and an umbrella-wide sweep for OS-process spawn sites. Claims below carry `file:line` citations.

---

## 1. Executive summary

The safe shell is **two systems with very different maturity, joined by one weak seam.**

**The inner boundary is genuinely strong.** For the agent-authorized path, `arbor_shell` implements a closed positive allowlist of 14 executables with per-command argv grammars, root-owned executable pinning verified by SHA-256 in both Elixir and C, `fexecve` on Linux (TOCTOU-free), forced environment clearing, and process-group containment that refuses to report a terminal state until it has *proven* the group is dead. Nothing ever reaches `/bin/sh -c`. There are zero `TODO`/`FIXME` markers anywhere in the subsystem, and every limitation is written down as prose in a moduledoc. This is unusually disciplined code.

**The outer boundary barely exists.** OS-level isolation enforced by the launcher amounts to exactly one rule — *you may not create another process* (Linux seccomp / macOS `sandbox-exec`). No rlimits, no namespaces, no uid change, no cgroups, no filesystem or network restriction. The strong containment story on macOS lives in the Apple Container subsystem, which is real and fail-closed but reachable **only** via `execute_spawn_capable/3` for the Mix validation workload, and only on macOS 26+/arm64 with operator-provisioned signed assets.

**The seam is the problem.** `Arbor.Shell.execute/2` and `execute_direct/3` do no authorization at all (documented as trusted-system-only), and **114 OS-process spawn sites across 41 files outside `arbor_shell` bypass the subsystem entirely**. Several are reachable from LLM-exposed Jido actions today with no `arbor://shell/exec/*` capability check and no approval gate.

The project already knows this. `.arbor/roadmap/1-brainstorming/safe-shell-execution.md:3` is still **Brainstorming** — no safe-shell item has been promoted to `2-planned/` or `3-in-progress/`, and gap #5 in that doc ("`Shell.execute/2` skips auth entirely… Needs an audit: which of these are agent-reachable?") is exactly the audit that had not been done. §5 below is that audit.

---

## 2. What exists today

### 2.1 Layout

| Layer | Modules | LOC |
|---|---|---|
| Core policy + execution | `shell.ex`, `executor.ex`, `sandbox.ex`, `executable_policy.ex`, `trusted_path.ex`, `cap_policy.ex`, `cap_shell.ex`, `config.ex`, `runtime_config_loader.ex` | ~4.4k |
| Process isolation | `c_src/arbor_shell_launcher.c`, `process_group.ex`, `port_session.ex`, `owned_tree.ex`, `execution_registry.ex`, `execution_worker.ex`, `startup_epoch.ex` | ~3.1k + 43 KB C |
| Apple Container | 24 × `apple_container_*.ex` | ~25.2k |
| Linux dependency baseline | 6 × `linux_dependency_baseline_*.ex` | ~5.5k |

51 test files, including 8 dedicated `*_security_regression_test.exs` modules.

### 2.2 The two execution surfaces

`apps/arbor_shell/lib/arbor/shell.ex:5-11` defines them explicitly:

1. **Native direct** (`execute/2`, `execute_direct/3`, `authorize_and_execute/3`) — argv-pinned, **childless by design** (`shell.ex:444`). The seccomp/sandbox-exec fork denial means `mix`, `git` hooks, and anything that spawns simply cannot run here.
2. **Spawn-capable** (`execute_spawn_capable/3`, `shell.ex:626`) — Apple Container VM. The only path where descendants are permitted.

The split is recorded in `.arbor/decisions/2026-07-13-spawn-capable-shell-containment.md:8-11`.

### 2.3 Authorization pipeline (agent path)

Twenty gates, in order, from `authorize_and_execute/3` to `execve`:

| # | Gate | Where |
|---|---|---|
| 1 | UTF-8 / non-empty / **compound rejection** / no control chars | `sandbox.ex:517` |
| 2 | argv split (`OptionParser.split`) | `sandbox.ex:536` |
| 3 | 14-name executable allowlist | `sandbox.ex:542`, list at `:48-50` |
| 4 | Per-command **closed argv grammar** | `sandbox.ex:554-619` |
| 5 | `:gate_command` basename equality | `sandbox.ex:703` |
| 6 | `:env` must be absent/empty | `sandbox.ex:508` |
| 7-8 | Startup-pinned executable resolution | `executable_policy.ex:98, 209, 276` |
| 9 | Root-owned trusted-path pin + SHA-256 + stat stability | `trusted_path.ex:64` |
| 10-11 | Principal shape + **injected external authorizer** (fail-closed if unconfigured) | `shell.ex:1162, 1167` |
| 12 | Option narrowing — force `sandbox: :basic`, force `clear_env: true`, drop `:env`/`:allowlist` | `shell.ex:1062` |
| 13-14 | Registry registration, timeout/output normalization | `shell.ex:1077`, `executor.ex:70` |
| 15 | argv NUL check, cwd canonicalize+pin, **re-verify** pinned identity, pinned child PATH | `process_group.ex:296-340` |
| 16-17 | Env construction, `Port.open({:spawn_executable, launcher}, args:)` — argv list, never a shell | `process_group.ex:761, 714-733` |
| 18 | **Native re-verify**: `O_NOFOLLOW` re-open, dev/ino/size/mtime/ctime/mode + SHA-256 | `launcher.c:962-1025, 360` |
| 19 | `setsid()`, `fchdir(cwd_fd)`, fork denial, `fexecve`/`execve` | `launcher.c:885-940, 475, 446` |
| 20 | Deadline + output ceiling + **proof-of-kill before terminal** | `process_group.ex:504, 403, 807` |

### 2.4 Allowlist, verbatim

```
cat echo false grep head ls printenv printf pwd sleep sort tail touch true wc
```
`sandbox.ex:48-50`. Each has an explicit argv grammar; the comment above it is worth reading — `sort` accepts only `-f -n -r -u` specifically to block `--compress-program` (`sandbox.ex:598-601`); `printenv` operands must match `^[A-Za-z_][A-Za-z0-9_]*$` (`:621-629`); unknown flags fail closed *before* authorization.

Shell metacharacters (`; & | ( ) \` $( > < \n \r`, `sandbox.ex:37`) are **rejected, never escaped** — including when quoted. `grep "a|b"` is refused. Documented as intentional at `sandbox.ex:34-36`.

### 2.5 Environment and path handling

- `PATH` is **always** overwritten with the pinned trusted search path — callers cannot set it (`executable_policy.ex:176`, `process_group.ex:761-789`).
- Agent paths force `clear_env: true` and it cannot be disabled, even via `sandbox: :none`. Rationale at `shell.ex:1055-1061`: so an authorized `printenv` cannot exfiltrate host credentials. Regression-tested in `agent_environment_security_regression_test.exs`.
- **Trusted paths (`execute/2`, `execute_direct/3`) default to `clear_env: false` and inherit the entire BEAM environment.** This is deliberate and regression-tested as intended (`agent_environment_security_regression_test.exs:112`), but it means every caller in §5.1 gets the full ambient env.
- Executable paths: every ancestor directory must be root-owned and not group/other-writable (`trusted_path.ex:247`), symlinks resolved component-wise with a 40-link cap, full SHA-256, 9-field stat-stability check against TOCTOU (`:310-326`), then re-verified in C.

### 2.6 Apple Container subsystem

Real, thorough, and correctly fail-closed. Highlights:

- Pins Apple's actual notarized binaries by team ID `UPBK2H6LZM` and per-binary designated requirements; runs **all three `codesign --verify --strict` checks before ever invoking `/usr/local/bin/container`** (`apple_container_prober.ex:111-114`).
- Images referenced by a **non-routable local alias** `127.0.0.1:0/arbor/workload@sha256:<digest>` with `--scheme https` — a missing image fails locally instead of pulling (`apple_container_plan_core.ex:11-18`).
- Fixed create argv: `--network none --no-dns --read-only --cap-drop ALL --init --tmpfs /tmp --workdir /workspace`, exactly 7 bind mounts with fixed guest targets, closed 12-entry env (`apple_container_plan_core.ex:1357-1390, 123-131`).
- Durable single-writer journal with fsync + descriptor-read proof + post-rename verification; **honestly documents that it is BEAM-crash-consistent, not power-loss-durable** (`apple_container_unit_journal.ex:6-10`).
- Drain coordinator restarts **closed** and stays closed until reconstruction positively converges (`apple_container_unit_drain_coordinator.ex:45-57`).
- ~880 tests, all host-independent; a live adversarial matrix harness exists at `tmp/run_apple_container_live_matrix.exs:38-51` covering `host_secret`, `network`, `double_fork`, `timeout`, `output_limit`, `cancellation`, `caller_death`.

**No fallback exists.** Every probe failure returns an error before any candidate process starts, and `Arbor.Actions.Mix` propagates rather than substituting (`apple_container_executor.ex:300-313`, `mix.ex:915-918`).

### 2.7 Linux dependency baseline

Despite the name, not a rootfs — it is a hash-inventoried, root-owned, pre-built `deps/` tree for `linux/arm64`, materialized into a private 0700 temp dir and bind-mounted as `MIX_DEPS_PATH`. Tree digest is a domain-separated, length-framed SHA-256 over the sorted inventory (`linux_dependency_baseline_core.ex:731-760`). Cross-bound to the container image via OCI labels `org.arbor.validation.{mix-lock-sha256,deps-tree-sha256}` (`apple_container_admission_core.ex:707-714`). Drift **poisons the boot epoch** and cascades a `rest_for_one` teardown of every downstream execution owner (`linux_dependency_baseline_authority.ex:174-181`).

---

## 3. What it cannot do

### 3.1 OS-level isolation is one rule: no forking

| Mechanism | Status |
|---|---|
| seccomp-BPF fork/vfork/clone/clone3 denial (Linux) | **Real** — `launcher.c:475-513`. Everything else is `SECCOMP_RET_ALLOW` (`:503`) |
| `PR_SET_NO_NEW_PRIVS` (Linux) | **Real** — `launcher.c:510` |
| `sandbox-exec` (macOS) | **Real but near-empty** — profile is literally `(version 1) (allow default) (deny process-fork)` (`launcher.c:66`). Also: `sandbox-exec` is deprecated by Apple |
| rlimits (CPU/AS/NOFILE/NPROC/FSIZE) | **None** |
| Namespaces (mount/pid/net/user/uts/ipc) | **None** |
| uid/gid change, capability drop | **None** — runs as the BEAM user |
| cgroups | **None** |
| chroot / pivot_root | **None** |
| Filesystem restriction | **None** beyond `fchdir` into a verified cwd |
| Network restriction | **None** |

Verified by grep over the whole C file: no `setrlimit`, `chroot`, `unshare`, `setuid`, `capset`, `sandbox_init`, `PR_SET_PDEATHSIG`. The binary is `0o755`, not setuid (`mix.exs:104`).

So an allowlisted `cat` in the native path can read anything the BEAM user can read, and `touch` — the one write-capable command in the allowlist — can create a file anywhere that user can write.

### 3.2 Operand paths are not constrained at all

`Sandbox.validate_operands/3` (`sandbox.ex:631-639`) rejects only tokens starting with `-`. **Zero validation on path values.** `cat /etc/passwd`, `grep x ../../secret`, `ls /`, and `touch /tmp/anything` are all structurally valid agent argv.

This is a documented delegation, not an oversight — `shell.ex:286-294, 445-448` states repository policy and workspace authorization belong to the injected authorizer and the Trust layer, not the Shell contract. It is nonetheless the single largest thing the subsystem does not do, and its correctness depends entirely on an external component.

### 3.3 Capability granularity is per-binary only

`apps/arbor_trust/lib/arbor/trust/profile_resolver.ex:241` says it plainly: `arbor://shell/exec/git` does not distinguish `git status` from `git push --force`. `VISION.md:121` aspires to *"'shell access for git: earned' is more selective and more legible than a score"* — that depends on subcommand granularity that does not exist yet.

### 3.4 Compound shell is retired, permanently

`CapShell.run/3` always fails closed (`cap_shell.ex:76-80`). `compound_shell_enabled?/0` is informational only and cannot re-enable it (`shell.ex:190-202`). `cap_shell.ex:35-49` lists the four upstream contracts required before any re-enable. `shell_execute_script` is likewise hard-disabled, schema retained only for catalog discoverability (`actions/shell.ex:445-456, 501-505`).

### 3.5 Platform coverage

- **Windows:** nothing. `docs/arbor/SECURITY_ARCHITECTURE.md:399-420` records the compatibility item as open.
- **Linux hosts:** no spawn-capable containment backend at all. The Apple Container path requires `{:unix, :darwin}` + arm64 (`apple_container_control_plane_authority.ex:479-485`).
- **Non-Linux/non-Darwin Unix:** launcher `_exit(126)` — fail-closed, nothing runs (`launcher.c:932-939`).
- **macOS:** requires operator-provisioned signed assets + `ARBOR_APPLE_CONTAINER_CONFIG_PATH`. Unconfigured hosts are *live but permanently closed*, which is the right posture. As `SECURITY_ARCHITECTURE.md:399-420` puts it: "code presence alone does not prove a host can execute this path."

### 3.6 `:container` sandbox level is a stub

`sandbox.ex:311-312, 355-359` returns `{:error, :container_not_implemented}`. Separately, `apps/arbor_sandbox` (Elixir *code* sandboxing, unrelated layer) has a `:container` level that is a literal no-op: `filesystem.ex:136` is `defp check_level_permission(:container, _), do: :ok`.

---

## 4. Narrower technical findings

Ordered roughly by severity within the subsystem itself.

1. **`:containment_failure` is not consulted by the caller.** A completed run flagged `containment_failure: true` returns `{:ok, result}`; `Arbor.Actions.Mix` computes `passed = result.exit_code == 0` (`mix.ex:3183, 3302`) and its `shell_capacity_termination?/1` checks only `timed_out|killed|output_limit_exceeded|cancelled` (`mix.ex:188-206`). A containment failure with exit code 0 reports as a **passing validation**. The flag is checked only on the git path (`mix.ex:2577`).

2. **No concurrency bound on executions.** `ExecutionRegistry.register/3` has no cap (`execution_registry.ex:101-124`) and `PortSessionSupervisor` is a bare `DynamicSupervisor` with no `:max_children` (`application.ex:112`). Nothing globally bounds simultaneous launcher processes / OS process groups.

3. **Registry entry + monitor leak.** `cleanup_state/2` (`execution_registry.ex:440-452`) evicts only terminal entries past TTL. A nonterminal entry whose owner neither dies nor publishes is never evicted, and its monitor is never flushed (`apply_terminal/4:331-342`). Controller-DOWN moves entries to `:cancelling` — still nonterminal (`:268-278`).

4. **Unbounded timeout on the one-shot path.** `Executor.normalize_timeout/1` accepts any positive integer with no ceiling (`executor.ex:110-112`); the 600 s cap exists only on the `PortSession` path (`port_session.ex:28, 744-748`).

5. **Blocking output write in the launcher.** `write_packet` → `write_all(STDOUT_FILENO, ...)` is blocking (`launcher.c:290-296, 228-240`) — the un-fixed mirror image of the stdin backpressure bug that `duplex_stdin_backpressure_security_regression_test.exs` was written for. Bounded in practice by eager BEAM port reads, but the asymmetry is real.

6. **32-bit inode truncation.** Darwin's synthetic 64-bit inode is compared masked to its low 32 bits for both target and cwd (`launcher.c:365-369, 1022`). Acknowledged in-comment; mitigated by the SHA-256 + dev + timestamps, but the cwd check has *only* dev + truncated ino.

7. **No `PR_SET_PDEATHSIG`, no parent-pid polling.** If the launcher itself is SIGKILLed, its target is not killed by the launcher — recovery depends on the BEAM's `kill` subcommand path (`process_group.ex:570-609`). If BEAM *and* launcher both die, the target survives.

8. **`:cwd` is not dropped by `agent_execution_opts/1`** (`shell.ex:1062-1067`), so an agent-boundary caller's cwd flows through unfiltered.

9. **`ProcessGroup` and the C launcher have no direct unit tests.** Coverage is indirect, and the two suites that exercise real OS pipes/process groups are `@moduletag :slow`, excluded from `mix test.fast`.

10. **Baseline manifest is unsigned.** Trust is rooted entirely in `uid 0` filesystem ownership. Also: verification re-hashes the whole tree (up to 512 MiB) ~6× per lease with no caching.

11. **No operator tooling or docs for the baseline.** `build_linux_dependency_baseline/2,3` is on the facade (`shell.ex:86-98`) with no mix task and no non-test caller; the builder returns a document but does not serialize the manifest. Grep of `docs/` for `linux_dependency_baseline` returns nothing.

12. **`chmod`-after-create ordering** in the materializer leaves a umask-dependent window on the private temp root (`materializer.ex:1228` after `owned_tree.ex:36`). Low severity; same-UID attackers are an explicitly documented carve-out (`owned_tree.ex:53-56`).

13. **Apple Container pins the 1.1.x compat line** (`apple_container_control_plane_admission_core.ex:39-40`) — a future Apple 1.2 fails closed and requires a code change. Intentional, but a hard operational coupling. Also, no `--user` flag in the create argv, so the guest runs as whatever UID the image sets.

---

## 5. The main finding: bypasses

**114 `System.cmd` / `Port.open` call sites across 41 files in `apps/*/lib` outside `arbor_shell`.** None get admission, capability check, `ApprovalGuard`, the execution registry, deadline/output ceilings, or process-group teardown.

Distribution: `arbor_common` 10 files, `arbor_actions` 10, `arbor_agent` 5, `arbor_orchestrator` 3, `arbor_integrations` 3, `arbor_cartographer` 3, `arbor_persistence` 2, `arbor_ai` 2, plus one each in `arbor_sandbox`, `arbor_llm`, `arbor_dashboard`.

### 5.1 Unauthorized `Arbor.Shell` entry points

`execute/2` and `execute_direct/3` perform no principal or Trust authorization — their own docstrings say so (`shell.ex:427, 460`). Callers include:

- `actions/code.ex:163, 190` — `Arbor.Shell.execute("mix compile --warnings-as-errors", sandbox: :none)` and `execute("mix test #{Enum.join(files, " ")}", sandbox: :none)`. **From `Arbor.Actions.Code.CompileAndTest`, which is a registered LLM-exposed action** (`arbor_actions.ex:1998`, URI `arbor://code/compile` at `:3078`). Agent-supplied `test_files` are string-interpolated into the command. `sandbox: :none` disables all checking (`sandbox.ex:124`).
- `actions/github.ex:111` — string reassembly via `ShellEscape.escape_arg/1`, then `execute(..., sandbox: :basic)`.
- `comms/channels/signal.ex:14, 32` — `command_runner: Arbor.Shell` for `signal-cli`. This is gap #5 from the roadmap doc, verbatim.
- `actions/mix.ex:2551`, `commands/coding_benchmark/git.ex:685` — `execute_direct/3` for git.

### 5.2 Tier 1 — LLM-reachable, bypass `arbor_shell` entirely

| Site | What | Action |
|---|---|---|
| `actions/file.ex:1045, 1081` | `System.cmd("rg" / "grep", args)` | `file_search` — agent-supplied pattern and file list |
| `actions/coding/review_tree.ex:328, 381` | `Port.open({:spawn_executable, git})`, `System.cmd("git", ...)` | `coding_review_tree_search` / `_read`. Hand-rolled bounded-output collector — a **parallel reimplementation of `Arbor.Shell.Executor`** |
| `actions/coding/workspace.ex:422, 689, 1477, 1488, 1607` | `git worktree add`, `merge-base`, generic `git/2` | `coding_workspace_acquire` / `_inspect` / `_release` / `_committed_change` |
| `actions/coding/workspace_lease_registry.ex:2418, 3711` | `System.cmd("realpath", ...)`, `git rev-parse` | Path canonicalization and tree-OID verification — **security primitives shelling out** |
| `actions/security/detectors/dependency_scan.ex:125` | `System.cmd("mix", ["hex.audit"])` | Runs **`mix`** — a descendant-spawning process — outside the `execute_spawn_capable` contract the 2026-07-13 decision says such commands require |
| `arbor_llm/file_receipt.ex:517` | `Port.open({:spawn_executable, "/usr/bin/perl"}, args: ["-e", script, ...])` | **Interpreter spawn with inline script** — exactly the class the agent boundary rejects |
| `arbor_integrations/documents.ex:161`, `documents/pdf.ex:392` | `python3 <script>`, `python3 -c <code>` | Interpreter spawns |
| `arbor_integrations/documents/pdf.ex:59,102,131,238,417,439,448`, `images.ex:50,81,107` | `pdfinfo`, `pdftotext`, `qpdf`, `pdftk`, `tesseract`, `pdftoppm`, `magick` | Memory-unsafe parsers on attacker-controlled file content |

Note the asymmetry: `shell_execute` is gated behind `arbor://shell` — which is in `ApprovalGuard`'s `@always_locked_uri_classes` (`approval_guard.ex:16`), classified `:critical, :irreversible, :require_human` with `graduation: false` (`capability_risk_profiles.ex:28`) — while `file_search`, `coding_review_tree_*`, `coding_workspace_*`, and `code_compile_and_test` reach real OS processes with none of that.

### 5.3 The two true shell-string sites

Both violate the stated core principle of `.arbor/decisions/2026-06-30-cap-checked-compound-shell.md` — *"Any design that parses with one engine and executes with another is bypassable no matter how good the parser is."*

- `apps/arbor_agent/lib/mix/tasks/arbor/template.ex:160` — `Port.open({:spawn, "#{editor} #{path}"}, ...)`. `{:spawn, string}` is **shell-interpreted**; `editor` comes from `$VISUAL`/`$EDITOR`, `path` from a user-supplied template name. No escaping.
- `apps/arbor_common/lib/mix/tasks/arbor/start.ex:259` — `System.cmd("sh", ["-c", elixir_cmd], env: System.get_env() |> ...)`. Explicit `sh -c` of a composed string with the **full ambient environment deliberately inherited** (comment at `:253-254`).

Both are mix tasks, so reachability is developer-invoked rather than agent-invoked — but they are the only remaining shell-string interpretation in the umbrella.

### 5.4 Why lint does not catch this

`lib/credo/checks/security/unsafe_system_cmd.ex` exists for exactly this class but only warns on *interpolated/dynamic* args (`:49-70`), so the ~90 literal-command sites pass clean. There is **no lint rule and no test enforcing "OS spawn must go through `Arbor.Shell`."** The source-grep technique that would catch it is used — but only *inside* `arbor_shell` (`apple_container_unit_recovery_worker_test.exs:953, 958`).

### 5.5 Naming hazard

Four unrelated things share the word "sandbox," which makes reasoning about this area harder than it should be:

- `Arbor.Shell.Sandbox` — shell metacharacter/argv policy
- `Arbor.Sandbox` — Elixir code + filesystem scoping (no OS processes at all; `code.ex:29-30` only *mentions* `System.cmd` in a list of what it blocks)
- `JidoSandbox` — sibling hex package, in-memory VFS + Lua, zero spawn sites (`jido_sandbox.ex:12`)
- The `sandbox: :none | :basic | :strict` option — a fourth, unrelated enum

`apps/arbor_contracts/lib/arbor/contracts/security/sandbox_level.ex:9` is the reconciliation table. None of these overlap with or duplicate `arbor_shell`.

---

## 6. What is planned

| Document | Status |
|---|---|
| `.arbor/roadmap/1-brainstorming/safe-shell-execution.md` | **Brainstorming** (raised 2026-06-10). "Needs a design pass before build." Master doc: parse → argv-exec → capability-allowlist → contain → escalate. Documents 5 verified auth gaps including the `execute/2` audit that §5 above completes |
| `.arbor/roadmap/1-brainstorming/shell-proxy-hitl-for-claude.md` | **Design — pre-implementation** (2026-06-07). Explicit non-goals: does not gate Claude's `Read`/`Write`/`Edit`/`Glob`/`Grep`/`WebFetch` |
| `.arbor/decisions/2026-06-30-cap-checked-compound-shell.md` | Accepted (route B3, embed `tv-labs/bash`) — **superseded in practice**; CapShell was retired and compound is now permanently fail-closed |
| `.arbor/decisions/2026-07-06-shell-parser-evaluation.md` | Proposed. Key framing: **parse ≠ contain** |
| `.arbor/decisions/2026-07-13-spawn-capable-shell-containment.md` | **Accepted, staged implementation.** Apple Container path — largely delivered |
| `docs/arbor-security-design.md:102-103` | **D7** (trust-tier sandboxing) and **D8** (reflex context completeness) — both High, both "Change implementation" |

**Nothing safe-shell-related sits in `2-planned/` or `3-in-progress/`.** `PLANNED.md` contains no shell item; `INPROGRESS.md` contains no shell item. `FEATURES.md:275-279, 361-376` lists shipped features and marks "container mode planned." There is **no spec domain for the shell** in `docs/specs/` — `TRUST-1.0.md` is the nearest adjacent artifact.

---

## 7. Recommendations

**Immediate, low-cost:**

1. Fix `template.ex:160` and `start.ex:259`. Two lines, and they are the only true shell-string interpretation left.
2. Make `Arbor.Actions.Mix` consult `:containment_failure` in `shell_capacity_termination?/1` (`mix.ex:188-206`) — a containment failure currently reports as a passing validation.
3. Add `:max_children` to `PortSessionSupervisor` and a registration cap to `ExecutionRegistry`; add a TTL sweep for nonterminal entries.
4. Add the ceiling from `port_session.ex:744-748` to `Executor.normalize_timeout/1`.

**Structural, and the actual fix:**

5. **Add an umbrella-wide enforcement rule** — extend the Credo check to flag *all* `System.cmd`/`Port.open` in `apps/*/lib` outside `arbor_shell`, backed by a source-grep test in the style of `apple_container_unit_recovery_worker_test.exs:953`, with an explicit reviewed allowlist. Roughly 90 sites currently pass silently. Without this, every bypass closed will be reopened.
6. **Close the Tier-1 action bypasses** (§5.2) — these are what an LLM can reach today with no capability and no approval gate. `review_tree.ex:328` in particular is reimplementing `Arbor.Shell.Executor`; that should be a direct-argv API on `Arbor.Shell`, not a parallel implementation.
7. **Promote safe-shell out of brainstorming.** The subsystem is now mature enough that the roadmap doc is stale in both directions — some gaps it lists are closed, and the biggest one (§5) is now measured rather than hypothetical.
8. **Write a `SHELL-1.0.md` spec domain.** Given the spec-packet workflow, this subsystem is the strongest candidate in the repo for one, and the absence of *any* documentation for `linux_dependency_baseline_*` (5.5k LOC, zero docs) makes the case.

**Longer-horizon, for the outer boundary:**

9. Add rlimits (`RLIMIT_AS`, `RLIMIT_NOFILE`, `RLIMIT_FSIZE`, `RLIMIT_CPU`) to the launcher. Cheap, portable, and closes the "unbounded memory/disk" gap on both platforms.
10. Decide whether operand-path constraint stays delegated to the authorizer. It is a defensible design, but today it means the strongest part of the system depends on a component outside it, and `touch` can write anywhere the service account can.
11. Native Linux containment (bubblewrap / namespaces + seccomp, or Landlock) remains the largest platform gap — there is no spawn-capable backend on Linux hosts at all.
