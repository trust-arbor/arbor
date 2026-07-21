# Applied Learning: Filesystem and Git

Read this when handling paths, files, symlinks, worktrees, Git provenance, indexes, hooks, cleanup roots, or formatter scope.

## Retained Applied Learning

<!-- applied-learning: portable-directory-cleanup-must-account-for-platform-specific-errno-atoms -->
<a id="applied-learning-portable-directory-cleanup-must-account-for-platform-specific-errno-atoms"></a>
**Portable directory cleanup must account for platform-specific errno atoms.**
On macOS, `File.rmdir/1` can return `{:error, :eexist}` for a non-empty
directory, where Linux typically returns `{:error, :enotempty}`. When a
non-empty shared directory is an expected benign outcome, handle both forms
while continuing to fail closed for other errors (found 2026-07-20 in
benchmark artifact lease cleanup).

<!-- applied-learning: inspect-formatter-diffs-before-staging-a-narrow-change -->
<a id="applied-learning-inspect-formatter-diffs-before-staging-a-narrow-change"></a>
**Inspect formatter diffs before staging a narrow change.** A source file may
predate the current formatter and a one-line comment edit can trigger broad,
unrelated layout churn. Format behavior-bearing files as required, then remove
incidental whole-file rewrites so the review surface stays scoped (found
2026-07-17 while correcting ACP eval-runner documentation).

<!-- applied-learning: do-not-run-mix-commands-in-the-main-worktree-while-a-compiled-dot-task-is-active -->
<a id="applied-learning-do-not-run-mix-commands-in-the-main-worktree-while-a-compiled-dot-task-is-active"></a>
**Do not run Mix commands in the main worktree while a compiled DOT task is
active.** Even a targeted test may recompile transitive modules on disk while
the running server still has the previous BEAM loaded. A task whose execution
manifest was already bound can then fail later with
`execution_module_loaded_code_mismatch` / `handler_binding_mismatch`; if its
retain node is rejected, owner-death cleanup can remove the dirty worktree.
Use an isolated worktree for every Mix command while delegated pipelines are
running, then hot-reload deliberately between tasks (found 2026-07-13 during
Phase 6 spawn/lifecycle delegation).

<!-- applied-learning: do-not-compile-or-test-the-active-checkout-while-a-subagent-is-midway-through-a-shared-file-edit -->
<a id="applied-learning-do-not-compile-or-test-the-active-checkout-while-a-subagent-is-midway-through-a-shared-file-edit"></a>
**Do not compile or test the active checkout while a subagent is midway through a shared-file edit.** Multi-agent commits share the parent workspace, so another focused test can observe a transient state between a new call site and its helper definitions and report unrelated compile errors. Wait for the owning worker to finish or test an isolated committed worktree (found 2026-07-10 during CodingPlan executor integration).

<!-- applied-learning: isolated-worktree-formatting-needs-the-dependency-path-too -->
<a id="applied-learning-isolated-worktree-formatting-needs-the-dependency-path-too"></a>
**Isolated worktree formatting needs the dependency path too.** The umbrella formatter imports dependency formatter configuration (for example Phoenix), so `mix format --check-formatted` in a clean worktree fails with an unknown `:import_deps` dependency unless `MIX_DEPS_PATH` points at fetched dependencies. Use the same shared `MIX_DEPS_PATH` setup as isolated compile/test commands (found 2026-07-10 during Phase 4 verification).

<!-- applied-learning: a-hashed-child-name-does-not-make-an-artifact-root-safe-from-symlinks -->
<a id="applied-learning-a-hashed-child-name-does-not-make-an-artifact-root-safe-from-symlinks"></a>
**A hashed child name does not make an artifact root safe from symlinks.** Deriving `trusted_base/task-<sha256>` prevents textual traversal, but a pre-created symlink at that child can still redirect all writes. Canonicalize/create the base, reject symlink children, create the task directory explicitly, and verify segment-aware containment before writing artifacts or Engine logs (found 2026-07-10 during CodingPlan executor review).

<!-- applied-learning: file-tools-need-both-exposure-and-fileguard-scope-grants -->
<a id="applied-learning-file-tools-need-both-exposure-and-fileguard-scope-grants"></a>
**File tools need both exposure and FileGuard scope grants.** `file_read` / `file_list` are selected via the bare action URI (`arbor://fs/read`, `arbor://fs/list`), but the final file gate authorizes the path-embedded URI synthesized from `file_path:` (for example `arbor://fs/read/Users/.../repo/file.ex`). For least-privilege repo access, use template shorthands like `arbor://fs/read/repo` only if lifecycle expands them into both the bare tool URI and an absolute repo-root `/**` scope, and make sure `ActionsExecutor` resolves relative LLM paths against the tool workdir before signing/authorization; otherwise chat can expose the tool but still deny the action at runtime (found 2026-07-07 while auditing Security Auditor and Test Agent).

<!-- applied-learning: glob-is-a-file-read-and-must-have-an-authorized-base -->
<a id="applied-learning-glob-is-a-file-read-and-must-have-an-authorized-base"></a>
**Glob is a file read and must have an authorized base.** `file_glob` shares the bare `arbor://fs/read` exposure URI with `file_read`, but its user-controlled path can live in `pattern` rather than `path`. A missing `base_path` used to skip FileGuard entirely: a repo-scoped read-only agent could glob `/private/tmp/...` because the action layer authorized only the bare `arbor://fs/read`. Agent/tool execution must inject an effective base path (normally the tool workdir), plumb `base_path` into fs auth, and reject absolute or `..` patterns when a base/workspace is set (found and reproduced 2026-07-07 via Security Auditor Eval).

<!-- applied-learning: canonical-dot-serialization-must-preserve-value-types-not-just-text -->
<a id="applied-learning-canonical-dot-serialization-must-preserve-value-types-not-just-text"></a>
**Canonical DOT serialization must preserve value types, not just text.** A binary attribute value such as `fan_out="false"` must remain quoted when a graph is serialized; emitting bare `fan_out=false` makes the parser coerce it to boolean `false`, while runtime code may deliberately distinguish the string form. That type drift silently re-enabled fan-out, queued a protocol-repair branch, and later blocked a security-profile join on impossible fan-in predecessors. Roundtrip tests must assert parsed value types as well as canonical bytes (found 2026-07-10 while enabling the reviewed security-regression profile).

<!-- applied-learning: verify-the-live-source-root-before-trusting-recompile -->
<a id="applied-learning-verify-the-live-source-root-before-trusting-recompile"></a>
**Verify the live source root before trusting `recompile`.** Tidewave or `arbor.recompile` may be attached to an isolated runtime snapshot such as `/private/tmp/arbor-runtime-current`, so `IEx.Helpers.recompile/0` can return `:ok` while the main checkout contains entirely new modules. Inspect both `Module.module_info(:compile)[:source]` and `:code.which/1` before interpreting behavior. When a restart would disrupt active work, hot-load only the exact reviewed source files in dependency order (nested struct definitions before modules that expand them); otherwise use the purpose-built restart. Never diagnose an old sentinel as a current-code failure until loaded identity is proven (expanded 2026-07-15 during the spawn-capable facade live proof).

<!-- applied-learning: copying-a-git-repository-is-not-commit-provenance -->
<a id="applied-learning-copying-a-git-repository-is-not-commit-provenance"></a>
**Copying a Git repository is not commit provenance.** A clean `git status` does not cover
ignored files, hooks, local config, alternates, or other executable `.git` metadata. For an
attested fixture, reconstruct a neutral repository from bounded OID-verified commit/tree/blob
objects, reject unsupported entries, and re-attest HEAD, tree, ancestry, and cleanliness before
and after execution. Disable replacement objects for every provenance command, and pass explicit
cleanliness flags such as `--untracked-files=all`; repository-local config can otherwise make an
unrelated commit appear ancestral or hide an untracked mutation.

<!-- applied-learning: git-hooks-that-invoke-bare-mix-bypass-the-repository-wrapper -->
<a id="applied-learning-git-hooks-that-invoke-bare-mix-bypass-the-repository-wrapper"></a>
**Git hooks that invoke bare `mix` bypass the repository wrapper.** The local pre-commit hook runs `mix format` and `mix run`; invoking `git commit` from a nested worktree with the ambient Homebrew PATH selected Elixir 1.20.2/OTP 29 and polluted the shared `_build` even though direct project commands correctly used `./bin/mix`. Until the hook itself is installed from a tracked, wrapper-aware script, run such commits with the pinned Erlang/Elixir `bin` directories first in `PATH` and an isolated `MIX_BUILD_PATH`; do not treat a hook-side dependency compile failure as a formatting failure (found 2026-07-09 during the workspace-lease slice).

<!-- applied-learning: gitignore-directory-patterns-with-a-trailing-slash-do-not-cover-worktree-symlinks -->
<a id="applied-learning-gitignore-directory-patterns-with-a-trailing-slash-do-not-cover-worktree-symlinks"></a>
**Gitignore directory patterns with a trailing slash do not cover worktree symlinks.** A delegated worker linked `_build` to the parent checkout; `/_build/` did not ignore the symlink, and `git add -A` committed it. Use `/_build` (and `/deps`) when both real directories and accidental symlinks must stay untracked. Also prefer the existing Mix action shared-path environment over creating links in a coding worktree (found 2026-07-09 during the workspace-lease slice).

<!-- applied-learning: use-canonical-private-tmp-paths-for-isolated-macos-worktrees-that-share-absolute-mix-paths -->
<a id="applied-learning-use-canonical-private-tmp-paths-for-isolated-macos-worktrees-that-share-absolute-mix-paths"></a>
**Use canonical `/private/tmp` paths for isolated macOS worktrees that share absolute Mix paths.** macOS aliases `/tmp` to `/private/tmp`, but dependency and build symlinks can retain the non-canonical spelling and break when Mix compares or resolves absolute paths. Create the worktree under `/private/tmp` and keep `MIX_BUILD_PATH`, deps paths, and symlink targets in that same canonical namespace (found 2026-07-10 during the Phase 3 combined verification).

<!-- applied-learning: git-status-shape-is-not-a-workspace-fingerprint -->
<a id="applied-learning-git-status-shape-is-not-a-workspace-fingerprint"></a>
**Git status shape is not a workspace fingerprint.** Rewriting an already-dirty or already-untracked file can leave `git status --porcelain` byte-for-byte unchanged. Turn-progress fingerprints must bind HEAD, staged index identities, and the actual content/metadata of every changed or untracked path. Bound paths/manifests/content and fail the inspect action closed on command, read, race, or limit errors; only the fixed digest may cross the Engine's JSON boundary (found 2026-07-15 while reviewing the owner-observed outcome fix).

<!-- applied-learning: an-in-process-test-formatter-is-not-a-hostile-code-proof-channel -->
<a id="applied-learning-an-in-process-test-formatter-is-not-a-hostile-code-proof-channel"></a>
**An in-process test formatter is not a hostile-code proof channel.** Candidate ExUnit/project code shares the BEAM with a generated formatter, so it can discover or replace formatter state, forge a schema-valid artifact, mutate shared dependencies, or halt with a chosen status. A two-revision coding gate must either run only after binding review of an exact immutable tree and name that limited assurance honestly, or use a genuinely external attested runtime; a random path, custom formatter, or container alone does not establish hostile-runtime integrity (found 2026-07-10 adversarially reviewing the Phase 5 security-regression runner).

<!-- applied-learning: pre-post-pathname-checks-do-not-bind-file-bytes-across-a-read -->
<a id="applied-learning-pre-post-pathname-checks-do-not-bind-file-bytes-across-a-read"></a>
**Pre/post pathname checks do not bind file bytes across a read.** An attacker can swap a path to alternate same-sized content for `File.read/1` and restore the original inode before the post-check. Security-sensitive source reads must open the canonical regular file once, compare the opened descriptor's identity with the authorized pathname identity, read only from that descriptor, then revalidate both descriptor and pathname before returning bytes (found 2026-07-10 after the first pipeline source-race fix still admitted a restored-path double-swap).

<!-- applied-learning: file-cp-r-2-preserves-symlink-targets-a-copied-tree-is-not-automatically-isolated -->
<a id="applied-learning-file-cp-r-2-preserves-symlink-targets-a-copied-tree-is-not-automatically-isolated"></a>
**`File.cp_r/2` preserves symlink targets; a copied tree is not automatically isolated.** Absolute symlinks inside a dependency tree still point back to the original tree after copying. Security-sensitive snapshots must inspect every copied symlink, reject source targets outside the trusted source root, and rewrite allowed internal links to targets inside the destination before treating the copy as private (verified 2026-07-10 while isolating two-revision validation dependencies).

<!-- applied-learning: reused-detached-worktree-build-paths-can-retain-stale-priv-symlinks -->
<a id="applied-learning-reused-detached-worktree-build-paths-can-retain-stale-priv-symlinks"></a>
**Reused detached-worktree build paths can retain stale `priv` symlinks.** Mix links an application's `_build/.../priv` back to the source worktree. Reusing `MIX_BUILD_PATH` with `--no-compile` after that worktree is removed can make shipped templates or other assets appear missing even though the target checkout contains them. Before trusting a `:not_found` result in an isolated rerun, inspect the build's `priv` target, rebuild in the target worktree, or deliberately refresh that symlink (found 2026-07-10 while rerunning exact-template policy tests).

<!-- applied-learning: run-authorization-test-fixtures-must-cross-the-ir-compilation-boundary -->
<a id="applied-learning-run-authorization-test-fixtures-must-cross-the-ir-compilation-boundary"></a>
**Run-authorization test fixtures must cross the IR compilation boundary.** `RunAuthorization.new/2` intentionally rejects raw `%Graph{}` values because execution authority binds the compiled graph and its manifest. Tests that construct a graph directly must compile it with `Arbor.Orchestrator.IR.Compiler` and use the enriched nodes from that compiled graph before creating authority or invoking handlers (found 2026-07-10 updating caller-authority regressions after Phase 5 hardening).

<!-- applied-learning: implicit-action-directory-context-must-be-schema-bound -->
<a id="applied-learning-implicit-action-directory-context-must-be-schema-bound"></a>
**Implicit action directory context must be schema-bound.** `ActionsExecutor` used to inject both `:cwd` and `:workdir` into every action after schema atomization. Strict actions correctly rejected those undeclared keys as `:unsupported_parameter`, so an approved `cross_app` validation never reached compile/xref/tests. Inject only the directory keys declared by the selected action schema, preserve explicit supported values, and regress the public executor-to-action boundary for actions declaring neither, either, and both keys (found 2026-07-10 during executable-profile dogfood).

<!-- applied-learning: canonicalize-temporary-resource-roots-before-deriving-mix-paths -->
<a id="applied-learning-canonicalize-temporary-resource-roots-before-deriving-mix-paths"></a>
**Canonicalize temporary resource roots before deriving Mix paths.** On macOS, `System.tmp_dir!/0` can return `/var/folders/...` while Mix and the filesystem resolve the same location as `/private/var/folders/...`. Deriving build and dependency paths from the non-canonical spelling can make Mix create broken relative `include` or `priv` symlinks, causing dependency compilation to fail before project tests start. Resolve the root once with `SafePath.resolve_real/1`, then derive every child path from that canonical root (found 2026-07-11 during security-regression validation).

<!-- applied-learning: two-revision-proof-lives-only-in-the-plan-s-immutable-requested-test-paths -->
<a id="applied-learning-two-revision-proof-lives-only-in-the-plan-s-immutable-requested-test-paths"></a>
**Two-revision proof lives only in the plan's immutable requested test paths.** A worker may add excellent regressions elsewhere, but the security validator copies and runs only `requested_paths` against base and candidate. Put every required public behavioral proof in one of those selected files before dispatch, or steer it there before commit; extra tests remain useful coverage but do not establish the pre-fix-fails claim (found 2026-07-11 reviewing shell-bound dogfood before validation).

<!-- applied-learning: an-absolute-bin-mix-path-does-not-select-that-checkout-as-the-project-root -->
<a id="applied-learning-an-absolute-bin-mix-path-does-not-select-that-checkout-as-the-project-root"></a>
**An absolute `bin/mix` path does not select that checkout as the project root.** The wrapper inherits the shell's current directory, so invoking `/tmp/worktree/bin/mix test ...` while `cwd` is the main checkout silently tests main and can produce a false base/candidate proof. `cd` into the exact detached worktree (or set the command workdir) before every compile/test, then use an isolated build path tied to that checkout (found 2026-07-11 while proving the signing-authority acquisition regression on its parent).

<!-- applied-learning: repository-git-hooks-must-use-bin-mix-not-ambient-mix -->
<a id="applied-learning-repository-git-hooks-must-use-bin-mix-not-ambient-mix"></a>
**Repository Git hooks must use `./bin/mix`, not ambient `mix`.** A pre-commit hook that invokes raw `mix` can select the wrong Elixir/OTP pair and contend on a different build lock than the repository wrapper; it may spend minutes compiling dependencies and never reach the commit even though the staged change is valid. Run the pinned wrapper for format/tests, and fix the hook to use the same wrapper rather than treating `--no-verify` as the normal path (found 2026-07-11 while checkpointing the signing-authority Engine slice).

<!-- applied-learning: arbor-s-git-facade-rejects-configured-execution-hooks-even-when-they-point-at-git-s-default-directory -->
<a id="applied-learning-arbor-s-git-facade-rejects-configured-execution-hooks-even-when-they-point-at-git-s-default-directory"></a>
**Arbor's Git facade rejects configured execution hooks even when they point at Git's default directory.** An explicit local `core.hooksPath=.git/hooks` (or its absolute equivalent) is still executable repository configuration, so `Arbor.Actions.Git.execute/2` fails closed with `{:unsafe_git_configuration, "core.hookspath\n"}` and coding workspace acquisition reports `:invalid_git_repository`. If no global/system hook path overrides the default, remove the redundant local setting; the existing `.git/hooks` remain active through Git's normal lookup. Do not weaken the facade or misdiagnose this as a missing repository (found 2026-07-13 while delegating the Phase 6 fixture-hardening slice).

<!-- applied-learning: opaque-ids-become-paths-when-they-are-used-as-filenames -->
<a id="applied-learning-opaque-ids-become-paths-when-they-are-used-as-filenames"></a>
**Opaque IDs become paths when they are used as filenames.** `Path.join(dir, "#{run_id}.json")` does not make an untrusted run ID safe; `../` segments can escape the fallback store and turn an ordinary get/save operation into an arbitrary JSON read or write. Validate the identifier against a closed filename grammar or resolve the final path through `SafePath` before IO, and regress through the public persistence/action boundary for both reads and writes (found 2026-07-11 while moving eval fallback persistence to its owning library).

<!-- applied-learning: git-porcelain-is-not-a-cleanliness-proof-until-hidden-index-flags-are-neutralized -->
<a id="applied-learning-git-porcelain-is-not-a-cleanliness-proof-until-hidden-index-flags-are-neutralized"></a>
**Git porcelain is not a cleanliness proof until hidden index flags are neutralized.** `assume-unchanged` and `skip-worktree` can hide modified tracked files from ordinary status/diff checks, allowing false `no_changes`, clean-commit, or failure-side-effect claims. In isolated verification clones, reject or clear non-normal flags before hashing and comparing the actual index/worktree/HEAD state (found 2026-07-11 reviewing benchmark Git invariants).

<!-- applied-learning: path-confinement-checks-must-bind-to-the-opened-file-not-only-the-pathname -->
<a id="applied-learning-path-confinement-checks-must-bind-to-the-opened-file-not-only-the-pathname"></a>
**Path confinement checks must bind to the opened file, not only the pathname.** `lstat`/`realpath` followed by `File.read` is still check-then-use: a leaf or ancestor can be swapped to a symlink/FIFO between calls. Open once without accepting symlink indirection, inspect the handle's type/device/inode, compare it to the confined path and stable ancestors, read bounded bytes from that same handle, and recheck stability; otherwise fail closed (found 2026-07-11 reviewing benchmark artifact IO).

<!-- applied-learning: plain-detached-git-worktrees-do-not-inherit-ignored-dependency-directories -->
<a id="applied-learning-plain-detached-git-worktrees-do-not-inherit-ignored-dependency-directories"></a>
**Plain detached Git worktrees do not inherit ignored dependency directories.** A manually created proof worktree usually has no `deps/`, so an isolated `MIX_BUILD_PATH` alone fails before tests. Point `MIX_DEPS_PATH` at the trusted main checkout's dependency cache (while keeping the build path isolated), or create the same reviewed dependency links as the workspace manager (found 2026-07-11 running parent security proofs).

<!-- applied-learning: temporary-test-roots-must-be-collision-safe-across-beam-invocations-not-only-within-one-vm -->
<a id="applied-learning-temporary-test-roots-must-be-collision-safe-across-beam-invocations-not-only-within-one-vm"></a>
**Temporary test roots must be collision-safe across BEAM invocations, not only within one VM.** `System.unique_integer/1` restarts with a new VM, so a predictable global `/tmp` path can collide with residue from an interrupted prior run. Allocate an exclusive random/OS-owned directory, register cleanup ownership before partial fixture construction, and regress stale-root behavior deterministically (found 2026-07-11 rerunning coding benchmark tests in an isolated worktree).

<!-- applied-learning: pinned-otp-file-timestamps-may-be-too-coarse-to-prove-same-read-stability -->
<a id="applied-learning-pinned-otp-file-timestamps-may-be-too-coarse-to-prove-same-read-stability"></a>
**Pinned OTP file timestamps may be too coarse to prove same-read stability.** On OTP 28.4.1, `time: :native` returns `{:error, :badarg}` and `time: :posix` exposes second-resolution mtime/ctime, so full metadata comparison can miss same-second, same-inode rewrites. Under a trusted owner-only root, read/hash the captured exact size twice from the same handle with EOF probes and require identical content digests plus stable metadata; document this as stable-content evidence, not a hostile atomic-snapshot guarantee (found 2026-07-11 after the persistence mutation regression failed under repetition).

<!-- applied-learning: do-not-ship-production-callable-test-hooks-that-alter-security-observations -->
<a id="applied-learning-do-not-ship-production-callable-test-hooks-that-alter-security-observations"></a>
**Do not ship production-callable test hooks that alter security observations.** Public `__test_*` setters backed by process dictionaries or ETS can let same-process code replace file identity, random-token, or cleanup evidence in real execution. Thread deterministic callbacks only through an explicitly test-only execution seam that the public production path rejects, or use a separately injected test owner; keep the enforcing module identical in its security decisions (found 2026-07-11 reviewing benchmark inode and run-root tests).

<!-- applied-learning: canonicalize-resource-identity-before-deleting-the-resource -->
<a id="applied-learning-canonicalize-resource-identity-before-deleting-the-resource"></a>
**Canonicalize resource identity before deleting the resource.** Realpath behavior changes after removal: on macOS a live `/var/...` path may resolve to `/private/var/...`, then fall back to lexical `/var/...` once absent, allowing a stale Git registration to evade an exact-path comparison. Capture the canonical identity while the path and parent exist, retain it in the lease, and compare later observations against that stable identity (found 2026-07-11 reviewing verified worktree cleanup).

<!-- applied-learning: long-lived-signing-roots-must-not-live-in-the-application-environment -->
<a id="applied-learning-long-lived-signing-roots-must-not-live-in-the-application-environment"></a>
**Long-lived signing roots must not live in the application environment.** `System.get_env/1` is readable by every module in the VM and inherited by ordinary subprocesses, so storing a private root there lets any action certify arbitrary sessions. Arbor should hold only the public key and a non-secret endpoint for an independently launched signer; remove the private value from the Arbor process environment and fail closed when the external authority is unavailable (found 2026-07-11 with a child-process execution-root probe).

<!-- applied-learning: a-public-helper-that-accepts-arbitrary-paths-is-an-authority-surface -->
<a id="applied-learning-a-public-helper-that-accepts-arbitrary-paths-is-an-authority-surface"></a>
**A public helper that accepts arbitrary paths is an authority surface.** Registry-internal filesystem machinery must stay private or require the same owner-issued lease/capability as its public workflow; module naming and `@doc false` do not prevent in-process candidate code from calling an exported function. Regress by invoking the former export and proving it cannot create the caller-selected destination (found 2026-07-13 reviewing the validation dependency snapshot helper).

<!-- applied-learning: in-tree-inode-de-duplication-cannot-detect-an-out-of-tree-hardlink -->
<a id="applied-learning-in-tree-inode-de-duplication-cannot-detect-an-out-of-tree-hardlink"></a>
**In-tree inode de-duplication cannot detect an out-of-tree hardlink.** A `MapSet` of device/inode pairs catches two names only when both are encountered during the same walk; a second hardlink outside the admitted root remains invisible. For immutable regular-file inputs, require the preflight link count to be exactly one and match the post-pin identity/stat fields, while retaining inode de-duplication as defense in depth for the enumerated tree (found 2026-07-14 reviewing the Linux dependency-baseline source verifier).

<!-- applied-learning: isolated-worktree-commit-hooks-may-need-the-canonical-dependency-cache-explicitly -->
<a id="applied-learning-isolated-worktree-commit-hooks-may-need-the-canonical-dependency-cache-explicitly"></a>
**Isolated worktree commit hooks may need the canonical dependency cache explicitly.** A coding worktree without local `deps/` can pass parent-owned review builds yet fail `git commit` when hooks invoke Mix from that worktree. Run the hook-backed commit with canonical `MIX_DEPS_PATH` and an appropriate reviewer-owned `MIX_BUILD_PATH`; do not bypass the hook or copy dependencies into the worktree merely to make the commit succeed (found 2026-07-14 preserving the materializer hardening commit from a stalled ACP worker).

<!-- applied-learning: do-not-parse-human-formatted-ls-output-into-build-or-environment-paths -->
<a id="applied-learning-do-not-parse-human-formatted-ls-output-into-build-or-environment-paths"></a>
**Do not parse human-formatted `ls` output into build or environment paths.** Interactive aliases and color settings can inject ANSI bytes into command substitution; a delegated test run then created a literal escape-prefixed directory and compiled into the wrong relative path. Use an explicit path, a shell glob array, or NUL-safe machine output such as `find -print0`, and keep generated build directories out of the staged diff (found 2026-07-14 reviewing the Actions baseline-lease correction).

<!-- applied-learning: never-feed-colorized-command-output-back-into-a-filesystem-command -->
<a id="applied-learning-never-feed-colorized-command-output-back-into-a-filesystem-command"></a>
**Never feed colorized command output back into a filesystem command.** ANSI prefixes/suffixes are data once captured; a colored temporary path can create a literal escape-named directory tree instead of targeting the intended worktree. Disable color (`NO_COLOR=1` or the tool's never-color flag), validate the captured scalar, and canonicalize it before reuse (found 2026-07-15 when an isolated validation build path included Git/Mix color escapes).

<!-- applied-learning: do-not-combine-shared-source-dependencies-with-a-fresh-isolated-build-tree-blindly -->
<a id="applied-learning-do-not-combine-shared-source-dependencies-with-a-fresh-isolated-build-tree-blindly"></a>
**Do not combine shared source dependencies with a fresh isolated build tree blindly.** Pointing a worktree's `MIX_DEPS_PATH` at the canonical `deps/` while giving it a new `MIX_BUILD_PATH` can force rebar dependencies such as `yamerl` to recompile from an incomplete fetched-source layout and fail on missing include headers. Use the worktree harness's prepared build, or validate the integrated commit in the canonical test build; sharing source deps is not equivalent to sharing a complete build cache (found 2026-07-15 independently validating L4 worker commits).

<!-- applied-learning: in-zsh-path-is-the-special-array-tied-to-path -->
<a id="applied-learning-in-zsh-path-is-the-special-array-tied-to-path"></a>
**In zsh, `path` is the special array tied to `PATH`.** Assigning `path=...` in a diagnostic one-liner can make later commands such as `git` and `sed` appear missing. Use a name such as `worktree_path` or `wt` for filesystem scalars (found 2026-07-15 while inspecting a retained coding worktree).

<!-- applied-learning: detached-worktree-formatter-hooks-still-need-formatter-dependencies -->
<a id="applied-learning-detached-worktree-formatter-hooks-still-need-formatter-dependencies"></a>
**Detached worktree formatter hooks still need formatter dependencies.** A clean worktree can have no local `deps/`, while `.formatter.exs` uses `import_deps`; bare `mix format` or a pre-commit formatting hook then fails with an unknown dependency even though the files are formatted. Run the repo wrapper with the canonical `MIX_DEPS_PATH` (and an isolated build path when needed) before diagnosing formatting drift (found 2026-07-16 integrating retained-workspace restart persistence).

<!-- applied-learning: keep-isolated-validation-builds-beneath-the-worktree-when-code-derives-authority-from-loaded-beam-ancestors -->
<a id="applied-learning-keep-isolated-validation-builds-beneath-the-worktree-when-code-derives-authority-from-loaded-beam-ancestors"></a>
**Keep isolated validation builds beneath the worktree when code derives authority from loaded BEAM ancestors.** `Arbor.Actions.Mix.resolve_mix_wrapper/0` walks upward from loaded code paths to find the reviewed source umbrella and executable `bin/mix`; an external `MIX_BUILD_PATH` severs that ancestry and makes otherwise healthy tests fail with `:mix_wrapper_unavailable`. Use an isolated path such as `$WORKTREE/_build/test` while sharing only the canonical dependency source when needed (found 2026-07-16 validating retained-workspace restart persistence).

<!-- applied-learning: never-hide-prior-exposure-by-chmod-repairing-an-existing-evidence-root-at-startup -->
<a id="applied-learning-never-hide-prior-exposure-by-chmod-repairing-an-existing-evidence-root-at-startup"></a>
**Never hide prior exposure by chmod-repairing an existing evidence root at startup.** An existing journal directory that is group/other-accessible may already contain planted evidence; changing it to `0700` before validation erases the signal without restoring provenance. Require existing roots and record files to already have the bound owner/private modes, and only chmod a newly created, owner-proven root or unpublished temp file (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: canonicalize-a-nonexistent-target-through-its-nearest-existing-ancestor -->
<a id="applied-learning-canonicalize-a-nonexistent-target-through-its-nearest-existing-ancestor"></a>
**Canonicalize a nonexistent target through its nearest existing ancestor.** `Path.expand/1` normalizes syntax but does not resolve an ancestor symlink or macOS's `/var` to `/private/var` alias. For authority comparisons involving a leaf that may already be gone or not yet created, resolve the nearest existing ancestor and append the missing suffix before comparing paths; otherwise aliases can bypass blockers or hide surviving registrations (found 2026-07-16 hardening retained-workspace creation and cleanup proofs).

<!-- applied-learning: parse-user-controlled-git-paths-with-nul-delimited-porcelain -->
<a id="applied-learning-parse-user-controlled-git-paths-with-nul-delimited-porcelain"></a>
**Parse user-controlled Git paths with NUL-delimited porcelain.** Newlines are valid in filesystem paths, so `git worktree list --porcelain` split on lines can turn one registration into several fake fields and make surviving evidence look absent. Request `-z`, parse records and fields on NUL boundaries in one owning facade, and make every cleanup/absence caller reuse that parser (found 2026-07-16 closing retained-workspace cleanup ambiguity).

<!-- applied-learning: a-no-clobber-publication-needs-an-explicit-linearization-marker-not-file-rename-2 -->
<a id="applied-learning-a-no-clobber-publication-needs-an-explicit-linearization-marker-not-file-rename-2"></a>
**A no-clobber publication needs an explicit linearization marker, not `File.rename/2`.** Portable rename semantics may replace an existing empty destination directory, and writing a marker directly at its final name exposes partial bytes. Reserve the output root exclusively, write and verify a private temporary marker, then atomically hard-link it to the final name as the last fallible operation; after that link succeeds, never return an error that would clean a publication another process can already observe (found 2026-07-16 hardening coding-benchmark fixture publication).

<!-- applied-learning: trusted-git-subprocesses-must-clear-ambient-repository-control-environment -->
<a id="applied-learning-trusted-git-subprocesses-must-clear-ambient-repository-control-environment"></a>
**Trusted Git subprocesses must clear ambient repository-control environment.** `GIT_DIR`, `GIT_WORK_TREE`, replace refs, global config, and lazy-fetch settings can redirect or alter otherwise fixed Git commands. Start provenance-sensitive Git with a closed environment, explicitly disable global/system config, replacement objects, prompting, and lazy fetch, and set a deterministic locale before interpreting output (found 2026-07-16 materializing pinned coding-benchmark fixtures).

<!-- applied-learning: never-run-mix-commands-concurrently-against-the-same-build-path -->
<a id="applied-learning-never-run-mix-commands-concurrently-against-the-same-build-path"></a>
**Never run Mix commands concurrently against the same build path.** Protocol consolidation rewrites shared files, so parallel commands can race and report missing `_build/*/consolidated/*.beam` artifacts even when both code paths are healthy. Run them sequentially or give each process a separate worktree-local build root (found 2026-07-16 validating contained Mix paths and runtime configuration).

<!-- applied-learning: hex-extraction-needs-a-writable-process-cwd-even-when-its-package-destination-is-writable -->
<a id="applied-learning-hex-extraction-needs-a-writable-process-cwd-even-when-its-package-destination-is-writable"></a>
**Hex extraction needs a writable process CWD even when its package destination is writable.** Hex 2.5.1 creates relative `tmp_*` extraction directories and does not honor `TMPDIR` for that step, so `mix deps.get` from a read-only mounted source fails with `:erofs`. Use a writable tracked-files-only staging checkout when validating a read-only production source (found 2026-07-16 building the Linux dependency baseline in Apple Container).

<!-- applied-learning: hot-reload-must-reconcile-loaded-code-with-the-code-path-beam-not-only-source-timestamps -->
<a id="applied-learning-hot-reload-must-reconcile-loaded-code-with-the-code-path-beam-not-only-source-timestamps"></a>
**Hot reload must reconcile loaded code with the code-path BEAM, not only source timestamps.** Remote `IEx.Helpers.recompile/0` returned `:ok` after a prior local compile had already made the shared on-disk BEAM newer, while the running module MD5 remained stale. `mix arbor.recompile` now compares loaded `module_info(:md5)` values with validated BEAM compiler MD5s for loaded `arbor_*` app modules and uses soft purge before loading exact disk bytes; verify those identities directly when behavior still appears stale (found and fixed 2026-07-16 while validating the Apple Container unit-name fix).

<!-- applied-learning: use-code-compile-file-1-not-repeated-code-require-file-1-when-iterating-a-live-rpc-diagnostic-module -->
<a id="applied-learning-use-code-compile-file-1-not-repeated-code-require-file-1-when-iterating-a-live-rpc-diagnostic-module"></a>
**Use `Code.compile_file/1`, not repeated `Code.require_file/1`, when iterating a live RPC diagnostic module.** `require_file` caches the path, so a modified ignored trace script can silently keep running its older module definition and make a correct diagnostic edit appear ineffective. `compile_file` deliberately replaces the loaded diagnostic module for the next run (found 2026-07-16 while validating the Apple Container wrapper-directory mount).

<!-- applied-learning: build-a-committable-git-tree-with-bulk-object-index-operations-not-one-update-index-process-per-path -->
<a id="applied-learning-build-a-committable-git-tree-with-bulk-object-index-operations-not-one-update-index-process-per-path"></a>
**Build a committable Git tree with bulk object/index operations, not one `update-index` process per path.** Rewriting a growing private index for each of 2,879 files made tree binding effectively quadratic and consumed the entire validation deadline before Mix started. Capture each file through the existing descriptor/identity checks into one bounded private stage, hash the staged paths in one Git operation, and feed one NUL-delimited `update-index --index-info` stream; regress the number of Git processes as the fixture grows (found 2026-07-16 during Phase 6 cross-app dogfood).

<!-- applied-learning: isolated-worktree-commit-hooks-need-access-to-the-shared-dependency-tree -->
<a id="applied-learning-isolated-worktree-commit-hooks-need-access-to-the-shared-dependency-tree"></a>
**Isolated worktree commit hooks need access to the shared dependency tree.** A reviewed worktree can compile and format with an explicitly shared `MIX_DEPS_PATH`, then have `git commit` fail when the hook launches Mix without that environment and the worktree has no local `deps/`. Preserve the same reviewed shared dependency path for the commit-hook process; do not bypass the hook or fetch a new unreviewed dependency tree merely to commit (found 2026-07-17 integrating the benchmark-adapter fixture split).

<!-- applied-learning: keep-isolated-validation-builds-under-the-checked-out-repository-when-code-root-authority-is-under-test -->
<a id="applied-learning-keep-isolated-validation-builds-under-the-checked-out-repository-when-code-root-authority-is-under-test"></a>
**Keep isolated validation builds under the checked-out repository when code-root authority is under test.** `Arbor.Actions.Mix.resolve_mix_wrapper/0` intentionally derives the trusted `bin/mix` wrapper from loaded BEAM paths; moving `MIX_BUILD_PATH` to an external temporary directory severs that ancestry and makes fixture validation fail closed with `:mix_wrapper_unavailable`. A detached worktree is sufficient isolation: use its local `_build` plus an explicit shared `MIX_DEPS_PATH`, and run each umbrella app's test paths from that app when Mix path routing would otherwise skip them (found 2026-07-18 verifying the cross-app aggregate budget calibration).

<!-- applied-learning: keep-fresh-isolated-mix-build-roots-inside-the-worktree -->
<a id="applied-learning-keep-fresh-isolated-mix-build-roots-inside-the-worktree"></a>
**Keep fresh isolated Mix build roots inside the worktree.** A detached verification using an external `/tmp/...` `MIX_BUILD_PATH` with an absolute shared `MIX_DEPS_PATH` made rebar compile `yamerl` without its `include/` headers, even though the headers existed; the same revision compiled with a worktree-local build root and with the known-good test build. Use a uniquely named worktree-local `_build_<task>` for cold verification, then remove it before commit, rather than assuming every Erlang dependency tolerates an out-of-tree build path (found 2026-07-18 independently verifying `task_216130`).

<!-- applied-learning: use-one-canonical-spelling-for-an-isolated-mix-build-path -->
<a id="applied-learning-use-one-canonical-spelling-for-an-isolated-mix-build-path"></a>
**Use one canonical spelling for an isolated Mix build path.** On macOS, a shell can enter a worktree through `/var/...` while `pwd` canonicalizes it to `/private/var/...`; setting `MIX_BUILD_PATH` with the noncanonical prefix made rebar dependency includes resolve against a mismatched tree and produced a false `yamerl` header failure. Derive the worktree-local build path from `$(pwd)` after entering the worktree so the checkout, build, and dependency paths share one canonical prefix (found 2026-07-18 verifying the Grok 4.5 provider pin).

<!-- applied-learning: a-custom-mix-build-path-must-be-environment-specific -->
<a id="applied-learning-a-custom-mix-build-path-must-be-environment-specific"></a>
**A custom `MIX_BUILD_PATH` must be environment-specific.** Reusing one custom build directory for a dev compile and a test run can reuse consolidated dev application configuration, so test-only settings such as `start_children: false` never take effect and durable live subsystems start inside the test VM. Keep separate canonical worktree-local build roots per `MIX_ENV`, or set `MIX_ENV=test` before both compilation and execution (found 2026-07-19 while validating coding-benchmark approval accounting).

<!-- applied-learning: a-strict-cwd-sandbox-cannot-use-linked-worktree-git-storage-without-a-separate-read-grant -->
<a id="applied-learning-a-strict-cwd-sandbox-cannot-use-linked-worktree-git-storage-without-a-separate-read-grant"></a>
**A strict CWD sandbox cannot use linked-worktree Git storage without a separate read grant.** The checkout files are inside the ACP worker's CWD, but its `.git` pointer resolves to the parent repository's common directory outside that root. For native Grok, use an owner-derived transient custom profile that extends `strict`, grants read-only access to the exact bidirectionally verified common directory, denies its own policy file after startup, and sets `GIT_OPTIONAL_LOCKS=0`; restore the project file before the first prompt. This permits `git status`/`git diff` while parent metadata writes and the parent working tree remain denied. Never trust a caller-supplied Git root or widen access to the parent checkout (found 2026-07-19 during the Phase 6 production strict-sandbox canary).

<!-- applied-learning: do-not-fake-a-tool-home-by-changing-home-and-then-calling-path-expand -->
<a id="applied-learning-do-not-fake-a-tool-home-by-changing-home-and-then-calling-path-expand"></a>
**Do not fake a tool home by changing `HOME` and then calling `Path.expand("~")`.**
`Path.expand/1` may resolve the OS account home rather than the newly assigned process
environment, so a test can overwrite real CLI configuration or credentials. Inject the
tool-specific home explicitly (for example `GROK_HOME`) and build fixture paths from that
absolute value; restore the environment in `on_exit` (found 2026-07-19 when a Grok sandbox
collision test wrote its temporary profile into the real `~/.grok`).

<!-- applied-learning: use-lstat-to-reject-a-symlink-leaf-without-rejecting-canonicalized-system-ancestors -->
<a id="applied-learning-use-lstat-to-reject-a-symlink-leaf-without-rejecting-canonicalized-system-ancestors"></a>
**Use `lstat` to reject a symlink leaf without rejecting canonicalized system ancestors.** `SafePath.resolve_real/1` can turn macOS `/var` into `/private/var`; requiring the resolved string to equal the caller's expanded spelling rejects an ordinary directory reached through a system alias. When the invariant is "the final path entry itself is not a symlink," require `File.lstat/1` to report the expected type, then use the canonical path for downstream containment and identity checks (found 2026-07-20 while testing terminal coding-evidence roots).

<!-- applied-learning: contained-mix-requires-pinned-runtime-roots-as-well-as-project-paths -->
<a id="applied-learning-contained-mix-requires-pinned-runtime-roots-as-well-as-project-paths"></a>
**Contained Mix requires pinned runtime roots as well as project paths.** `ARBOR_MIX_CONTAINED=1` makes `bin/mix` bypass mise, so `MIX_BUILD_PATH` and `MIX_DEPS_PATH` are not sufficient by themselves: the wrapper also requires executable `ARBOR_ERLANG_ROOT` and `ARBOR_ELIXIR_ROOT`, otherwise it exits 127 before Mix starts. For isolated verification, derive both pinned roots from `.tool-versions` via mise, keep the build path inside the worktree, point only dependencies at the canonical cache, and remove the temporary build afterward (found 2026-07-21 while correcting the evidence-ref worker's worktree validation).
