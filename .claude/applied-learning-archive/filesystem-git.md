# Applied Learning archive: filesystem-git

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: isolated-worktree-formatting-needs-the-dependency-path-too -->
<a id="applied-learning-isolated-worktree-formatting-needs-the-dependency-path-too"></a>
**Isolated worktree formatting needs the dependency path too.** The umbrella formatter imports dependency formatter configuration (for example Phoenix), so `mix format --check-formatted` in a clean worktree fails with an unknown `:import_deps` dependency unless `MIX_DEPS_PATH` points at fetched dependencies. Use the same shared `MIX_DEPS_PATH` setup as isolated compile/test commands (found 2026-07-10 during Phase 4 verification).

<!-- applied-learning: detached-worktree-formatter-hooks-still-need-formatter-dependencies -->
<a id="applied-learning-detached-worktree-formatter-hooks-still-need-formatter-dependencies"></a>
**Detached worktree formatter hooks still need formatter dependencies.** A clean worktree can have no local `deps/`, while `.formatter.exs` uses `import_deps`; bare `mix format` or a pre-commit formatting hook then fails with an unknown dependency even though the files are formatted. Run the repo wrapper with the canonical `MIX_DEPS_PATH` (and an isolated build path when needed) before diagnosing formatting drift (found 2026-07-16 integrating retained-workspace restart persistence).

<!-- applied-learning: isolated-worktree-commit-hooks-may-need-the-canonical-dependency-cache-explicitly -->
<a id="applied-learning-isolated-worktree-commit-hooks-may-need-the-canonical-dependency-cache-explicitly"></a>
**Isolated worktree commit hooks may need the canonical dependency cache explicitly.** A coding worktree without local `deps/` can pass parent-owned review builds yet fail `git commit` when hooks invoke Mix from that worktree. Run the hook-backed commit with canonical `MIX_DEPS_PATH` and an appropriate reviewer-owned `MIX_BUILD_PATH`; do not bypass the hook or copy dependencies into the worktree merely to make the commit succeed (found 2026-07-14 preserving the materializer hardening commit from a stalled ACP worker).

<!-- applied-learning: isolated-worktree-commit-hooks-need-access-to-the-shared-dependency-tree -->
<a id="applied-learning-isolated-worktree-commit-hooks-need-access-to-the-shared-dependency-tree"></a>
**Isolated worktree commit hooks need access to the shared dependency tree.** A reviewed worktree can compile and format with an explicitly shared `MIX_DEPS_PATH`, then have `git commit` fail when the hook launches Mix without that environment and the worktree has no local `deps/`. Preserve the same reviewed shared dependency path for the commit-hook process; do not bypass the hook or fetch a new unreviewed dependency tree merely to commit (found 2026-07-17 integrating the benchmark-adapter fixture split).

<!-- applied-learning: use-canonical-private-tmp-paths-for-isolated-macos-worktrees-that-share-absolute-mix-paths -->
<a id="applied-learning-use-canonical-private-tmp-paths-for-isolated-macos-worktrees-that-share-absolute-mix-paths"></a>
**Use canonical `/private/tmp` paths for isolated macOS worktrees that share absolute Mix paths.** macOS aliases `/tmp` to `/private/tmp`, but dependency and build symlinks can retain the non-canonical spelling and break when Mix compares or resolves absolute paths. Create the worktree under `/private/tmp` and keep `MIX_BUILD_PATH`, deps paths, and symlink targets in that same canonical namespace (found 2026-07-10 during the Phase 3 combined verification).

<!-- applied-learning: use-one-canonical-spelling-for-an-isolated-mix-build-path -->
<a id="applied-learning-use-one-canonical-spelling-for-an-isolated-mix-build-path"></a>
**Use one canonical spelling for an isolated Mix build path.** On macOS, a shell can enter a worktree through `/var/...` while `pwd` canonicalizes it to `/private/var/...`; setting `MIX_BUILD_PATH` with the noncanonical prefix made rebar dependency includes resolve against a mismatched tree and produced a false `yamerl` header failure. Derive the worktree-local build path from `$(pwd)` after entering the worktree so the checkout, build, and dependency paths share one canonical prefix (found 2026-07-18 verifying the Grok 4.5 provider pin).

<!-- applied-learning: two-revision-proof-lives-only-in-the-plan-s-immutable-requested-test-paths -->
<a id="applied-learning-two-revision-proof-lives-only-in-the-plan-s-immutable-requested-test-paths"></a>
**Two-revision proof lives only in the plan's immutable requested test paths.** A worker may add excellent regressions elsewhere, but the security validator copies and runs only `requested_paths` against base and candidate. Put every required public behavioral proof in one of those selected files before dispatch, or steer it there before commit; extra tests remain useful coverage but do not establish the pre-fix-fails claim (found 2026-07-11 reviewing shell-bound dogfood before validation).

<!-- applied-learning: in-zsh-path-is-the-special-array-tied-to-path -->
<a id="applied-learning-in-zsh-path-is-the-special-array-tied-to-path"></a>
**In zsh, `path` is the special array tied to `PATH`.** Assigning `path=...` in a diagnostic one-liner can make later commands such as `git` and `sed` appear missing. Use a name such as `worktree_path` or `wt` for filesystem scalars (found 2026-07-15 while inspecting a retained coding worktree).

<!-- applied-learning: do-not-use-path-as-a-zsh-loop-variable -->
<a id="applied-learning-do-not-use-path-as-a-zsh-loop-variable"></a>
**Do not use `path` as a zsh loop variable.** In zsh, lowercase `path` is a
special array tied to `PATH`; assigning a worktree pathname to it replaces
command lookup and makes tools such as `git` appear missing. Use names like
`wt_path` or `repo_path` in portable shell loops (found 2026-07-22 during attached-worktree inventory).

<!-- applied-learning: keep-isolated-validation-builds-under-the-checked-out-repository-when-code-root-authority-is-under-test -->
<a id="applied-learning-keep-isolated-validation-builds-under-the-checked-out-repository-when-code-root-authority-is-under-test"></a>
**Keep isolated validation builds under the checked-out repository when code-root authority is under test.** `Arbor.Actions.Mix.resolve_mix_wrapper/0` intentionally derives the trusted `bin/mix` wrapper from loaded BEAM paths; moving `MIX_BUILD_PATH` to an external temporary directory severs that ancestry and makes fixture validation fail closed with `:mix_wrapper_unavailable`. A detached worktree is sufficient isolation: use its local `_build` plus an explicit shared `MIX_DEPS_PATH`, and run each umbrella app's test paths from that app when Mix path routing would otherwise skip them (found 2026-07-18 verifying the cross-app aggregate budget calibration).

<!-- applied-learning: verify-the-live-source-root-before-trusting-recompile -->
<a id="applied-learning-verify-the-live-source-root-before-trusting-recompile"></a>
**Verify the live source root before trusting `recompile`.** Tidewave or `arbor.recompile` may be attached to an isolated runtime snapshot such as `/private/tmp/arbor-runtime-current`, so `IEx.Helpers.recompile/0` can return `:ok` while the main checkout contains entirely new modules. Inspect both `Module.module_info(:compile)[:source]` and `:code.which/1` before interpreting behavior. When a restart would disrupt active work, hot-load only the exact reviewed source files in dependency order (nested struct definitions before modules that expand them); otherwise use the purpose-built restart. Never diagnose an old sentinel as a current-code failure until loaded identity is proven (expanded 2026-07-15 during the spawn-capable facade live proof).

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

<!-- applied-learning: never-run-mix-commands-concurrently-against-the-same-build-path -->
<a id="applied-learning-never-run-mix-commands-concurrently-against-the-same-build-path"></a>
**Never run Mix commands concurrently against the same build path.** Protocol consolidation rewrites shared files, so parallel commands can race and report missing `_build/*/consolidated/*.beam` artifacts even when both code paths are healthy. Run them sequentially or give each process a separate worktree-local build root (found 2026-07-16 validating contained Mix paths and runtime configuration).

<!-- applied-learning: inspect-formatter-diffs-before-staging-a-narrow-change -->
<a id="applied-learning-inspect-formatter-diffs-before-staging-a-narrow-change"></a>
**Inspect formatter diffs before staging a narrow change.** A source file may
predate the current formatter and a one-line comment edit can trigger broad,
unrelated layout churn. Format behavior-bearing files as required, then remove
incidental whole-file rewrites so the review surface stays scoped (found
2026-07-17 while correcting ACP eval-runner documentation).

<!-- applied-learning: checkpoint-proof-cache-boundaries-and-progress -->
<a id="applied-learning-checkpoint-proof-cache-boundaries-and-progress"></a>
**Checkpointed historical proofs are observations, never mutation authority.** Bind every reusable result to the exact repository, destination ref/OID, branch ref/OID, and proof-policy version; persist only closed, sanitized statuses; retry transient failures; and make progress count cache hits, every retry, and budget-skipped targets independently of outcome success.

<!-- applied-learning: do-not-parse-human-formatted-ls-output-into-build-or-environment-paths -->
<a id="applied-learning-do-not-parse-human-formatted-ls-output-into-build-or-environment-paths"></a>
**Do not parse human-formatted `ls` output into build or environment paths.** Interactive aliases and color settings can inject ANSI bytes into command substitution; a delegated test run then created a literal escape-prefixed directory and compiled into the wrong relative path. Use an explicit path, a shell glob array, or NUL-safe machine output such as `find -print0`, and keep generated build directories out of the staged diff (found 2026-07-14 reviewing the Actions baseline-lease correction).

<!-- applied-learning: do-not-combine-shared-source-dependencies-with-a-fresh-isolated-build-tree-blindly -->
<a id="applied-learning-do-not-combine-shared-source-dependencies-with-a-fresh-isolated-build-tree-blindly"></a>
**Do not combine shared source dependencies with a fresh isolated build tree blindly.** Pointing a worktree's `MIX_DEPS_PATH` at the canonical `deps/` while giving it a new `MIX_BUILD_PATH` can force rebar dependencies such as `yamerl` to recompile from an incomplete fetched-source layout and fail on missing include headers. Use the worktree harness's prepared build, or validate the integrated commit in the canonical test build; sharing source deps is not equivalent to sharing a complete build cache (found 2026-07-15 independently validating L4 worker commits).

<!-- applied-learning: pre-post-pathname-checks-do-not-bind-file-bytes-across-a-read -->
<a id="applied-learning-pre-post-pathname-checks-do-not-bind-file-bytes-across-a-read"></a>
**Pre/post pathname checks do not bind file bytes across a read.** An attacker can swap a path to alternate same-sized content for `File.read/1` and restore the original inode before the post-check. Security-sensitive source reads must open the canonical regular file once, compare the opened descriptor's identity with the authorized pathname identity, read only from that descriptor, then revalidate both descriptor and pathname before returning bytes (found 2026-07-10 after the first pipeline source-race fix still admitted a restored-path double-swap).

<!-- applied-learning: canonicalize-resource-identity-before-deleting-the-resource -->
<a id="applied-learning-canonicalize-resource-identity-before-deleting-the-resource"></a>
**Canonicalize resource identity before deleting the resource.** Realpath behavior changes after removal: on macOS a live `/var/...` path may resolve to `/private/var/...`, then fall back to lexical `/var/...` once absent, allowing a stale Git registration to evade an exact-path comparison. Capture the canonical identity while the path and parent exist, retain it in the lease, and compare later observations against that stable identity (found 2026-07-11 reviewing verified worktree cleanup).

<!-- applied-learning: git-hooks-that-invoke-bare-mix-bypass-the-repository-wrapper -->
<a id="applied-learning-git-hooks-that-invoke-bare-mix-bypass-the-repository-wrapper"></a>
**Git hooks that invoke bare `mix` bypass the repository wrapper.** The local pre-commit hook runs `mix format` and `mix run`; invoking `git commit` from a nested worktree with the ambient Homebrew PATH selected Elixir 1.20.2/OTP 29 and polluted the shared `_build` even though direct project commands correctly used `./bin/mix`. Until the hook itself is installed from a tracked, wrapper-aware script, run such commits with the pinned Erlang/Elixir `bin` directories first in `PATH` and an isolated `MIX_BUILD_PATH`; do not treat a hook-side dependency compile failure as a formatting failure (found 2026-07-09 during the workspace-lease slice).
