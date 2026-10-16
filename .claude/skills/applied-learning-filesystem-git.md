# Applied Learning: Filesystem and Git

Read this when handling paths, files, symlinks, worktrees, Git provenance, indexes, hooks, cleanup roots, or formatter scope.

## Retained Applied Learning

<!-- applied-learning: inspect-generated-command-helpers-before-execution -->
<a id="applied-learning-inspect-generated-command-helpers-before-execution"></a>
**Inspect generated command helpers before execution.** Check the actual file
bytes, shell syntax, and intended argument boundaries before the first invocation,
especially after multi-file patches. A missing patch delimiter can append document
content to an otherwise valid command and change its argv. On 2026-10-14, a local
Mix validation helper accidentally included the next file's patch header; source
inspection exposed the malformed command before any upstream build ran.

<!-- applied-learning: put-ripgrep-filters-before-the-option-terminator -->
<a id="applied-learning-put-ripgrep-filters-before-the-option-terminator"></a>
**Put ripgrep filters before the option terminator.** When a search pattern
begins with `-`, write options first and then `--`, for example
`rg -g '*.ex' -- '--cookie|--name' paths`. Putting `-g` after `--` makes it a
path, while omitting `--` makes the pattern an option (found 2026-10-06 while
tracing distribution-cookie exposure).

<!-- applied-learning: portable-directory-cleanup-must-account-for-platform-specific-errno-atoms -->
<a id="applied-learning-portable-directory-cleanup-must-account-for-platform-specific-errno-atoms"></a>
**Portable directory cleanup must account for platform-specific errno atoms.**
On macOS, `File.rmdir/1` can return `{:error, :eexist}` for a non-empty
directory, where Linux typically returns `{:error, :enotempty}`. When a
non-empty shared directory is an expected benign outcome, handle both forms
while continuing to fail closed for other errors (found 2026-07-20 in
benchmark artifact lease cleanup).

<!-- applied-learning: do-not-compile-or-test-the-active-checkout-while-a-subagent-is-midway-through-a-shared-file-edit -->
<a id="applied-learning-do-not-compile-or-test-the-active-checkout-while-a-subagent-is-midway-through-a-shared-file-edit"></a>
**Do not compile or test the active checkout while a subagent is midway through a shared-file edit.** Multi-agent commits share the parent workspace, so another focused test can observe a transient state between a new call site and its helper definitions and report unrelated compile errors. Wait for the owning worker to finish or test an isolated committed worktree (found 2026-07-10 during CodingPlan executor integration).

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

<!-- applied-learning: copying-a-git-repository-is-not-commit-provenance -->
<a id="applied-learning-copying-a-git-repository-is-not-commit-provenance"></a>
**Copying a Git repository is not commit provenance.** A clean `git status` does not cover
ignored files, hooks, local config, alternates, or other executable `.git` metadata. For an
attested fixture, reconstruct a neutral repository from bounded OID-verified commit/tree/blob
objects, reject unsupported entries, and re-attest HEAD, tree, ancestry, and cleanliness before
and after execution. Disable replacement objects for every provenance command, and pass explicit
cleanliness flags such as `--untracked-files=all`; repository-local config can otherwise make an
unrelated commit appear ancestral or hide an untracked mutation.

<!-- applied-learning: gitignore-directory-patterns-with-a-trailing-slash-do-not-cover-worktree-symlinks -->
<a id="applied-learning-gitignore-directory-patterns-with-a-trailing-slash-do-not-cover-worktree-symlinks"></a>
**Gitignore directory patterns with a trailing slash do not cover worktree symlinks.** A delegated worker linked `_build` to the parent checkout; `/_build/` did not ignore the symlink, and `git add -A` committed it. Use `/_build` (and `/deps`) when both real directories and accidental symlinks must stay untracked. Also prefer the existing Mix action shared-path environment over creating links in a coding worktree (found 2026-07-09 during the workspace-lease slice).

<!-- applied-learning: git-status-shape-is-not-a-workspace-fingerprint -->
<a id="applied-learning-git-status-shape-is-not-a-workspace-fingerprint"></a>
**Git status shape is not a workspace fingerprint.** Rewriting an already-dirty or already-untracked file can leave `git status --porcelain` byte-for-byte unchanged. Turn-progress fingerprints must bind HEAD, staged index identities, and the actual content/metadata of every changed or untracked path. Bound paths/manifests/content and fail the inspect action closed on command, read, race, or limit errors; only the fixed digest may cross the Engine's JSON boundary (found 2026-07-15 while reviewing the owner-observed outcome fix).

A clean-checkout guard must distinguish successful Git execution from a clean
worktree. Inspect the exact public status and phase receipts before changing
source; nonempty combined stdout/stderr alone does not identify a dirty path.
Preserve an unexpected generated diagnostic without reading or deleting its
contents: require a regular nonsymlink source, an exclusive private same-filesystem
destination, no overwrite, and matching inode/device/size/mtime/mode/link-count/owner
across the rename, then recheck cleanliness. Retain the failed attempt. Aggregate
receipts must include the last completed phase and a fixed non-sensitive failure
enum even when a semantic refusal happens before the phase is appended; missing
aggregate rows are not source-identity or process-liveness evidence (2026-10-05 Main
adoption stopped safely on an untracked Erlang crash dump).

<!-- applied-learning: an-in-process-test-formatter-is-not-a-hostile-code-proof-channel -->
<a id="applied-learning-an-in-process-test-formatter-is-not-a-hostile-code-proof-channel"></a>
**An in-process test formatter is not a hostile-code proof channel.** Candidate ExUnit/project code shares the BEAM with a generated formatter, so it can discover or replace formatter state, forge a schema-valid artifact, mutate shared dependencies, or halt with a chosen status. A two-revision coding gate must either run only after binding review of an exact immutable tree and name that limited assurance honestly, or use a genuinely external attested runtime; a random path, custom formatter, or container alone does not establish hostile-runtime integrity (found 2026-07-10 adversarially reviewing the Phase 5 security-regression runner).

<!-- applied-learning: file-cp-r-2-preserves-symlink-targets-a-copied-tree-is-not-automatically-isolated -->
<a id="applied-learning-file-cp-r-2-preserves-symlink-targets-a-copied-tree-is-not-automatically-isolated"></a>
**`File.cp_r/2` preserves symlink targets; a copied tree is not automatically isolated.** Absolute symlinks inside a dependency tree still point back to the original tree after copying. Security-sensitive snapshots must inspect every copied symlink, reject source targets outside the trusted source root, and rewrite allowed internal links to targets inside the destination before treating the copy as private (verified 2026-07-10 while isolating two-revision validation dependencies).

Retained-artifact inventories must also preserve empty directories and their
parents. A files-and-links-only inventory omitted an accepted empty dependency
`priv` target on 2026-10-04, so the confined copied link dangled before compilation.
Bind the exact accepted empty-directory set and validate it before copying links;
preserve the stopped setup receipt separately from product or compile failures.

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
**Canonicalize macOS temporary roots before deriving Mix paths.** Keep the worktree, dependency directory, build directory, and any symlink targets in one canonical namespace before a nested or Rebar-backed build. Resolve `/tmp` to `/private/tmp` and `/var` to `/private/var` with `Arbor.Common.SafePath.resolve_real/1` before exporting `MIX_DEPS_PATH` or `MIX_BUILD_PATH`. A lexical alias and its resolved spelling are different directories to tools that do not canonicalize, so a nested build can miss includes or write beside the intended tree. Apply that same spelling to every process that shares those absolute paths. (Merged 2026-10-16 from 5 entries; first found 2026-07-10, last 2026-10-09.)

<!-- applied-learning: an-absolute-bin-mix-path-does-not-select-that-checkout-as-the-project-root -->
<a id="applied-learning-an-absolute-bin-mix-path-does-not-select-that-checkout-as-the-project-root"></a>
**An absolute `bin/mix` path does not select that checkout as the project root.** The wrapper inherits the shell's current directory, so invoking `/tmp/worktree/bin/mix test ...` while `cwd` is the main checkout silently tests main and can produce a false base/candidate proof. `cd` into the exact detached worktree (or set the command workdir) before every compile/test, then use an isolated build path tied to that checkout (found 2026-07-11 while proving the signing-authority acquisition regression on its parent).

<!-- applied-learning: repository-git-hooks-must-use-bin-mix-not-ambient-mix -->
<a id="applied-learning-repository-git-hooks-must-use-bin-mix-not-ambient-mix"></a>
**Repository git hooks must invoke ./bin/mix, not ambient mix.** `./bin/mix` selects the toolchain pinned in `.tool-versions` and the repository's isolated `MIX_BUILD_PATH`. A hook that calls bare `mix` uses whatever Elixir is on `PATH` and can compile against the wrong build. A dependency compile started by the hook is not a format failure. The hook environment is a fresh process, so an export from the operator shell does not reach it. Do not use `--no-verify` as the normal way to commit. (Merged 2026-10-16 from 2 entries; first found 2026-07-09, last 2026-07-11.)

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
**Path confinement must bind the opened file, not only the pathname.** Pin the authorized root, open descendants with `openat` and `O_NOFOLLOW`, and read only that regular-file descriptor. The walk lives in `apps/arbor_shell/c_src/arbor_shell_launcher.c` (`walk_openat_segments`). A pre-check and a post-check of the pathname do not bind the bytes: a swap during the read, restored afterward, passes both name checks. Revalidate the descriptor and the pathname identity before returning bytes. The native helper must live in trusted runtime code, not on an agent-writable path. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-11.)

<!-- applied-learning: plain-detached-git-worktrees-do-not-inherit-ignored-dependency-directories -->
<a id="applied-learning-plain-detached-git-worktrees-do-not-inherit-ignored-dependency-directories"></a>
**Run detached worktrees with one pinned toolchain and an explicit dependency path.** A plain detached git worktree does not inherit ignored dependency directories. Run formatting, compilation, tests, and commit hooks through `./bin/mix` with an explicit `MIX_DEPS_PATH` and an isolated `MIX_BUILD_PATH`. A pre-commit hook can invoke Mix even when compilation was not the requested command, and an earlier format command does not export that environment into the hook. When the execution root changes, confirm the formatter options resolved for that root. Formatter configs that import dependency formatter plugins, including `apps/arbor_dashboard/.formatter.exs`, fail if those plugins are absent. Do not bypass hooks, copy dependencies into the worktree, or fetch unreviewed dependencies to satisfy the hook. (Merged 2026-10-16 from 6 entries; first found 2026-07-10, last 2026-07-28.)

<!-- applied-learning: temporary-test-roots-must-be-collision-safe-across-beam-invocations-not-only-within-one-vm -->
<a id="applied-learning-temporary-test-roots-must-be-collision-safe-across-beam-invocations-not-only-within-one-vm"></a>
**Temporary test roots must be collision-safe across BEAM invocations, not only within one VM.** `System.unique_integer/1` restarts with a new VM, so a predictable global `/tmp` path can collide with residue from an interrupted prior run. Allocate an exclusive random/OS-owned directory, register cleanup ownership before partial fixture construction, and regress stale-root behavior deterministically (found 2026-07-11 rerunning coding benchmark tests in an isolated worktree). Separate checkouts alone do not isolate `System.tmp_dir!/0`: simultaneous candidate/predecessor Voice journeys reused a migrated SQLite database until their fixture roots included OS process identity and an exclusively created random suffix (2026-09-27). This recurred on 2026-10-07 when a fresh Security suite reopened an earlier malformed authority inventory because its global temp leaf used `System.unique_integer/1` plus `mkdir_p`.

<!-- applied-learning: pinned-otp-file-timestamps-may-be-too-coarse-to-prove-same-read-stability -->
<a id="applied-learning-pinned-otp-file-timestamps-may-be-too-coarse-to-prove-same-read-stability"></a>
**Pinned OTP file timestamps may be too coarse to prove same-read stability.** On OTP 28.4.1, `time: :native` returns `{:error, :badarg}` and `time: :posix` exposes second-resolution mtime/ctime, so full metadata comparison can miss same-second, same-inode rewrites. Under a trusted owner-only root, read/hash the captured exact size twice from the same handle with EOF probes and require identical content digests plus stable metadata; document this as stable-content evidence, not a hostile atomic-snapshot guarantee (found 2026-07-11 after the persistence mutation regression failed under repetition).

<!-- applied-learning: do-not-ship-production-callable-test-hooks-that-alter-security-observations -->
<a id="applied-learning-do-not-ship-production-callable-test-hooks-that-alter-security-observations"></a>
**Do not ship production-callable test hooks that alter security observations.** Public `__test_*` setters backed by process dictionaries or ETS can let same-process code replace file identity, random-token, or cleanup evidence in real execution. Thread deterministic callbacks only through an explicitly test-only execution seam that the public production path rejects, or use a separately injected test owner; keep the enforcing module identical in its security decisions (found 2026-07-11 reviewing benchmark inode and run-root tests).

<!-- applied-learning: long-lived-signing-roots-must-not-live-in-the-application-environment -->
<a id="applied-learning-long-lived-signing-roots-must-not-live-in-the-application-environment"></a>
**Long-lived signing roots must not live in the application environment.** `System.get_env/1` is readable by every module in the VM and inherited by ordinary subprocesses, so storing a private root there lets any action certify arbitrary sessions. Arbor should hold only the public key and a non-secret endpoint for an independently launched signer; remove the private value from the Arbor process environment and fail closed when the external authority is unavailable (found 2026-07-11 with a child-process execution-root probe).

<!-- applied-learning: a-public-helper-that-accepts-arbitrary-paths-is-an-authority-surface -->
<a id="applied-learning-a-public-helper-that-accepts-arbitrary-paths-is-an-authority-surface"></a>
**A public helper that accepts arbitrary paths is an authority surface.** Registry-internal filesystem machinery must stay private or require the same owner-issued lease/capability as its public workflow; module naming and `@doc false` do not prevent in-process candidate code from calling an exported function. Regress by invoking the former export and proving it cannot create the caller-selected destination (found 2026-07-13 reviewing the validation dependency snapshot helper).

<!-- applied-learning: in-tree-inode-de-duplication-cannot-detect-an-out-of-tree-hardlink -->
<a id="applied-learning-in-tree-inode-de-duplication-cannot-detect-an-out-of-tree-hardlink"></a>
**In-tree inode de-duplication cannot detect an out-of-tree hardlink.** A `MapSet` of device/inode pairs catches two names only when both are encountered during the same walk; a second hardlink outside the admitted root remains invisible. For immutable regular-file inputs, require the preflight link count to be exactly one and match the post-pin identity/stat fields, while retaining inode de-duplication as defense in depth for the enumerated tree (found 2026-07-14 reviewing the Linux dependency-baseline source verifier).

<!-- applied-learning: never-feed-colorized-command-output-back-into-a-filesystem-command -->
<a id="applied-learning-never-feed-colorized-command-output-back-into-a-filesystem-command"></a>
**Never feed colorized command output back into a filesystem command.** Disable color with `NO_COLOR` or the tool's never-color flag before capturing output. Do not parse `ls` or a colored command substitution into a path. Use an explicit path, a shell glob array, or NUL-delimited `find -print0`. Validate and canonicalize a captured path with `Arbor.Common.SafePath.resolve_real/1` before reuse. A colored glyph in captured output is data, not a separator to strip by eye. Human formatting and ANSI sequences are not a machine path format. (Merged 2026-10-16 from 2 entries; first found 2026-07-14, last 2026-07-15.)

<!-- applied-learning: restart-durable-immutable-materialization-requires-an-owned-workspace -->
<a id="applied-learning-restart-durable-immutable-materialization-requires-an-owned-workspace"></a>
**Restart-durable immutable materialization requires an owned workspace.** Arbor
can retain, reactivate, and eventually clean a task-created worktree after owner
death; it has neither retention nor deletion authority over a reused caller-owned
path. Reject reused workspaces before allocating immutable validation resources or
evidence refs whenever downstream checkpoints promise exact-lineage recovery, and
leave the reused directory untouched (found 2026-09-02 while reviewing G5D
candidate materialization).

<!-- applied-learning: keep-isolated-validation-builds-beneath-the-worktree-when-code-derives-authority-from-loaded-beam-ancestors -->
<a id="applied-learning-keep-isolated-validation-builds-beneath-the-worktree-when-code-derives-authority-from-loaded-beam-ancestors"></a>
**Keep isolated validation builds under the checkout when authority walks loaded BEAM ancestors.** `Arbor.Actions.Mix.resolve_mix_wrapper/0` walks loaded anchors and returns `{:error, :mix_wrapper_unavailable}` when no reviewed wrapper is found. The default resolver fails closed. Put `_build` inside the worktree under test and share only `MIX_DEPS_PATH`, so the loaded beams' ancestors stay inside the checkout whose authority is being tested. An out-of-tree build path makes the walk miss the wrapper and deny the run. A hermetic test shell may supply `resolve_mix_wrapper/0`; that test seam does not widen the production resolver. (Merged 2026-10-16 from 3 entries; first found 2026-07-13, last 2026-07-18.)

<!-- applied-learning: destructive-git-cas-success-requires-clean-output-and-authoritative-post-observation -->
<a id="applied-learning-destructive-git-cas-success-requires-clean-output-and-authoritative-post-observation"></a>
**Destructive Git CAS success requires clean output and authoritative post-observation.** An exit-zero `git update-ref` can still carry unexpected output, and the mutation may already have happened; do not report clean success or assume an error preserved the old state. Require exact expected stdout/stderr, return stable residue for dirty success, and reconcile the exact ref/OID through structured observation on retry (found 2026-07-21 while hardening managed branch deletion and hidden evidence-ref creation).

<!-- applied-learning: never-hide-prior-exposure-by-chmod-repairing-an-existing-evidence-root-at-startup -->
<a id="applied-learning-never-hide-prior-exposure-by-chmod-repairing-an-existing-evidence-root-at-startup"></a>
**Never hide prior exposure by chmod-repairing an existing evidence root at startup.** An existing journal directory that is group/other-accessible may already contain planted evidence; changing it to `0700` before validation erases the signal without restoring provenance. Require existing roots and record files to already have the bound owner/private modes, and only chmod a newly created, owner-proven root or unpublished temp file (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: canonicalize-a-nonexistent-target-through-its-nearest-existing-ancestor -->
<a id="applied-learning-canonicalize-a-nonexistent-target-through-its-nearest-existing-ancestor"></a>
**Canonicalize a missing target through its nearest existing ancestor.** `Path.expand/1` does not resolve ancestor symlinks or the `/var` to `/private/var` alias. For a leaf that is not present yet, resolve the nearest existing ancestor and append the missing suffix. Capture that canonical identity while the path exists. After deletion, a realpath-style lookup falls back to a lexical form, so later comparisons must use the identity retained from before the delete. `Arbor.Common.SafePath.resolve_real/1` is the resolver for a path that exists. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-16.)

<!-- applied-learning: parse-user-controlled-git-paths-with-nul-delimited-porcelain -->
<a id="applied-learning-parse-user-controlled-git-paths-with-nul-delimited-porcelain"></a>
**Parse user-controlled Git paths with NUL-delimited porcelain.** Newlines are valid in filesystem paths, so `git worktree list --porcelain` split on lines can turn one registration into several fake fields and make surviving evidence look absent. Request `-z`, parse records and fields on NUL boundaries in one owning facade, and make every cleanup/absence caller reuse that parser (found 2026-07-16 closing retained-workspace cleanup ambiguity).

<!-- applied-learning: a-no-clobber-publication-needs-an-explicit-linearization-marker-not-file-rename-2 -->
<a id="applied-learning-a-no-clobber-publication-needs-an-explicit-linearization-marker-not-file-rename-2"></a>
**A no-clobber publication needs an explicit linearization marker, not `File.rename/2`.** Portable rename semantics may replace an existing empty destination directory, and writing a marker directly at its final name exposes partial bytes. Reserve the output root exclusively, write and verify a private temporary marker, then atomically hard-link it to the final name as the last fallible operation; after that link succeeds, never return an error that would clean a publication another process can already observe (found 2026-07-16 hardening coding-benchmark fixture publication).

<!-- applied-learning: trusted-git-subprocesses-must-clear-ambient-repository-control-environment -->
<a id="applied-learning-trusted-git-subprocesses-must-clear-ambient-repository-control-environment"></a>
**Trusted Git subprocesses must clear ambient repository-control environment.** `GIT_DIR`, `GIT_WORK_TREE`, replace refs, global config, and lazy-fetch settings can redirect or alter otherwise fixed Git commands. Start provenance-sensitive Git with a closed environment, explicitly disable global/system config, replacement objects, prompting, and lazy fetch, and set a deterministic locale before interpreting output (found 2026-07-16 materializing pinned coding-benchmark fixtures).

<!-- applied-learning: hex-extraction-needs-a-writable-process-cwd-even-when-its-package-destination-is-writable -->
<a id="applied-learning-hex-extraction-needs-a-writable-process-cwd-even-when-its-package-destination-is-writable"></a>
**Hex extraction needs a writable process CWD even when its package destination is writable.** Hex 2.5.1 creates relative `tmp_*` extraction directories and does not honor `TMPDIR` for that step, so `mix deps.get` from a read-only mounted source fails with `:erofs`. Use a writable tracked-files-only staging checkout when validating a read-only production source (found 2026-07-16 building the Linux dependency baseline in Apple Container).

<!-- applied-learning: hot-reload-must-reconcile-loaded-code-with-the-code-path-beam-not-only-source-timestamps -->
<a id="applied-learning-hot-reload-must-reconcile-loaded-code-with-the-code-path-beam-not-only-source-timestamps"></a>
**Reconcile hot reload against the code-path BEAM, not only source timestamps.** `Arbor.Common.CodeReloader` compares `module_info(:md5)` with `:beam_lib.md5/1` and then soft-purges. `mix arbor.recompile` is the reload task. Before diagnosing a closed-envelope rejection as a producer bug, compare producer and consumer source roots and the loaded beam with the beam on the code path. Reconcile reviewed modules between tasks. Preserve the consumer boundary: `Arbor.Shell.OciExecutionCore` and `Arbor.Shell.AppleContainerExecutionCore` accept read-write projections only for `:worktree`, `:home`, `:tmp`, `:build`, `:deps`, and `:validation_result`, and reject anything else with `:extra_projections`. Do not widen that closed set to match a stale producer. (Merged 2026-10-16 from 3 entries; first found 2026-07-15, last 2026-07-16.)

<!-- applied-learning: use-code-compile-file-1-not-repeated-code-require-file-1-when-iterating-a-live-rpc-diagnostic-module -->
<a id="applied-learning-use-code-compile-file-1-not-repeated-code-require-file-1-when-iterating-a-live-rpc-diagnostic-module"></a>
**Use `Code.compile_file/1`, not repeated `Code.require_file/1`, when iterating a live RPC diagnostic module.** `require_file` caches the path, so a modified ignored trace script can silently keep running its older module definition and make a correct diagnostic edit appear ineffective. `compile_file` deliberately replaces the loaded diagnostic module for the next run (found 2026-07-16 while validating the Apple Container wrapper-directory mount).

<!-- applied-learning: build-a-committable-git-tree-with-bulk-object-index-operations-not-one-update-index-process-per-path -->
<a id="applied-learning-build-a-committable-git-tree-with-bulk-object-index-operations-not-one-update-index-process-per-path"></a>
**Build a committable Git tree with bulk object/index operations, not one `update-index` process per path.** Rewriting a growing private index for each of 2,879 files made tree binding effectively quadratic and consumed the entire validation deadline before Mix started. Capture each file through the existing descriptor/identity checks into one bounded private stage, hash the staged paths in one Git operation, and feed one NUL-delimited `update-index --index-info` stream; regress the number of Git processes as the fixture grows (found 2026-07-16 during Phase 6 cross-app dogfood).

<!-- applied-learning: keep-fresh-isolated-mix-build-roots-inside-the-worktree -->
<a id="applied-learning-keep-fresh-isolated-mix-build-roots-inside-the-worktree"></a>
**Keep a fresh isolated Mix build root inside the worktree.** A fresh `MIX_BUILD_PATH` outside the worktree, combined with shared source dependencies, can break Rebar include lookup. Use a worktree-local build directory named for that task and remove it before commit. This is separate from wrapper discovery that walks loaded BEAM ancestors: the failure here is include resolution, and the fix is still a build root inside the checkout. Do not point a clean build at an out-of-tree directory while compiling against shared in-tree deps. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-18.)

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

<!-- applied-learning: fail-closed-bulk-audits-still-need-closed-useful-error-categories -->
<a id="applied-learning-fail-closed-bulk-audits-still-need-closed-useful-error-categories"></a>
**Fail-closed bulk audits still need closed, useful error categories.** A generic sanitizer that accepts only atoms, binaries, and two-tuples can turn known bounded failures such as `{:range_too_large, :destination, 256}` or a killed Git storage check into `unknown`. Preserve explicitly recognized structural categories and safe numeric fields while retaining `unknown` for arbitrary payloads; otherwise a conservative manifest is secure but not reviewable or operable (found 2026-07-21 while inspecting the historical coding-branch audit).

<!-- applied-learning: do-not-rely-on-posix-scalar-word-splitting-in-zsh -->
<a id="applied-learning-do-not-rely-on-posix-scalar-word-splitting-in-zsh"></a>
**Do not rely on POSIX scalar word splitting in zsh diagnostics.** With zsh's default options, `set -- $pair` preserves a scalar containing spaces as one argument rather than splitting it into positional parameters, so a comparison loop can report false mismatches against an empty path. Use an explicit array, `${=pair}` only when deliberate, or pass each path directly; verify harness failures before treating them as repository-state failures (found 2026-07-21 while proving historical branch-settlement set equality).

<!-- applied-learning: stage-owned-paths-and-reconcile-duplicate-terminal-evidence -->
<a id="applied-learning-stage-owned-paths-and-reconcile-duplicate-terminal-evidence"></a>
**Stage only explicitly owned paths, and reconcile duplicate terminal evidence.** In a shared
worktree, unrelated workers may modify adjacent files or introduce compile failures; never use
`git add -A` or broad staging. When one fact is represented at both a top-level result and an
artifact boundary, normalize both through the same closed contract and reject disagreement
instead of committing contradictory evidence (found 2026-07-21 during Phase 7A lifecycle work).

<!-- applied-learning: unsigned-local-checkpoint-successes-are-revalidation-hints-only -->
<a id="applied-learning-unsigned-local-checkpoint-successes-are-revalidation-hints-only"></a>
**Unsigned local checkpoint successes are revalidation hints only.** A reusable proof binds the exact repository, destination ref and OID, branch ref and OID, and policy version. An unsigned local success, including owner-only mode, establishes confidentiality of the local result, not authenticity, and must spend the normal proof budget again. Only an exact-scope deterministic preserve outcome may skip work. Persist only closed sanitized statuses. Count cache hits, retries, and budget-skipped targets separately from success. (Merged 2026-10-16 from 2 entries; first found 2026-07-21, last 2026-07-21.)

<!-- applied-learning: host-maintenance-scripts-must-target-system-runtime-apis -->
<a id="applied-learning-host-maintenance-scripts-must-target-system-runtime-apis"></a>
**Host maintenance scripts must target system-runtime APIs.** macOS' bundled Ruby can predate `Enumerable#filter_map`; a local branch audit failed before classification when a diagnostic assumed it. For dependency-free `ruby` one-liners, use broadly supported constructs such as `map { ... }.compact`, or invoke an explicitly pinned runtime (found 2026-07-22 during local branch cleanup).
Stdlib extensions are not loaded implicitly either: require the owning library
explicitly (for example, `require "tmpdir"` before `Dir.tmpdir`) instead of
assuming another tool already loaded it (found 2026-07-23 during worktree
settlement).

<!-- applied-learning: verify-source-escapes-remain-text-after-agent-edits -->
<a id="applied-learning-verify-source-escapes-remain-text-after-agent-edits"></a>
**Verify source escapes remain text after agent edits.** An editor or tool-call
transport can decode a source literal such as `\u0000` into a real NUL byte while
rewriting a test, causing Git to classify the whole file as binary and hiding the
ordinary line diff. When an edited source file unexpectedly becomes binary, inspect
its NUL count and force the intended language escape to remain textual; review the
result with `git diff --text` before accepting it (found 2026-07-28 when a Claude ACP
edit converted an Elixir invalid-input fixture into a literal NUL). When writing
sentinel bytes through nested JavaScript, shell, or Python escaping, prefer numeric
bytes (for example, `bytes([10])`) and inspect the final bytes; an overescaped
newline can append the two literal characters instead of a line feed (found
2026-10-07 while restoring EOF newlines after a security review).

<!-- applied-learning: verify-requested-deletions-are-git-deletions-not-empty-tracked-files -->
<a id="applied-learning-verify-requested-deletions-are-git-deletions-not-empty-tracked-files"></a>
**Verify requested deletions are Git deletions, not empty tracked files.** An
agent editor can implement "remove this module" by truncating a tracked source
file to zero bytes. Compilation may still pass because an empty source file is
valid, while the dead path remains in the repository. Before approving the
commit gate, require `git status --short` to report `D` for every requested
deletion and verify the committed summary records delete mode; preserve a
useful dirty candidate in a separate salvage worktree before correcting it
(found 2026-07-29 when the inert Engine Budget middleware and its test were
emptied rather than deleted).

<!-- applied-learning: git-apply-three-way-updates-the-index -->
<a id="applied-learning-git-apply-three-way-updates-the-index"></a>
**`git apply --3way` updates the index.** A clean three-way patch can leave all
applied paths staged even when the intent was only to import a worker's diff
into the working tree. Immediately inspect `git diff --cached --name-only`
after integration and run `git restore --staged -- <owned paths>` when no
commit or staging was requested; then verify worktree bytes separately. Do not
use broad unstaging in a shared dirty tree (found 2026-07-31 while integrating
Phase E provider attestation).

<!-- applied-learning: rsync-accepts-one-destination-per-invocation -->
<a id="applied-learning-rsync-accepts-one-destination-per-invocation"></a>
**`rsync` accepts one destination per invocation.** A command that alternates
several source and destination paths treats every argument except the last as a
source and can merge unrelated trees into that final destination. Multiple
individual sources sent to one directory also flatten to their basenames instead
of preserving each source path. When syncing an isolated validation worktree,
run one explicit source/exact-file destination pair per invocation (or use a
verified relative-root mode), then inspect status before testing (found
2026-07-31 and reinforced 2026-08-01 during Phase E validation).

<!-- applied-learning: stacked-candidate-adoption-requires-preserving-the-exact-base-ancestry -->
<a id="applied-learning-stacked-candidate-adoption-requires-preserving-the-exact-base-ancestry"></a>
**Stacked candidate adoption requires preserving the exact base ancestry.** The bounded adoption
proof compares candidate and destination ranges rooted at the candidate's full base OID. If a
repair is dispatched atop an unintegrated retained candidate and both commits are later
cherry-picked, Git rewrites both OIDs and the original base is not a destination ancestor even
though the resulting tree contains the patches. Integrate the prerequisite before dispatching
the repair, or deliberately preserve the stacked ancestry; do not assume tree equivalence alone
can settle retained task evidence. If an accepted stack was already cherry-picked, first prove the
destination contains the full task-tip change and inspect every remaining delta; only then may an
explicit no-content ancestry merge preserve the exact base/tip lineage. Never use an `ours` merge
as a substitute for integrating or reviewing content (found 2026-08-02 adopting the VP-04D1 race
repair; reinforced 2026-08-15 settling the stacked E0B2P dependency-binding repair).

<!-- applied-learning: hardened-git-can-reject-repositories-that-ordinary-git-accepts -->
<a id="applied-learning-hardened-git-can-reject-repositories-that-ordinary-git-accepts"></a>
**Hardened Git can reject repositories that ordinary Git accepts.** Arbor's Git boundary denies
repository-local settings that can launch helper processes, including `core.fsmonitor`; workspace
acquisition currently collapses that denial to `:invalid_git_repository`. When ordinary Git
succeeds but `coding_workspace_acquire` reports an invalid repository, probe
`Arbor.Actions.Git.execute(repo, ["rev-parse", "--show-toplevel"])` or audit local process-bearing
Git config before retrying. Remove the setting only when doing so preserves the intended hardened
workflow (found 2026-08-03 when Voice VP-05D1 acquisition masked `core.fsmonitor=true`).

<!-- applied-learning: target-every-post-worktree-git-mutation-explicitly -->
<a id="applied-learning-target-every-post-worktree-git-mutation-explicitly"></a>
**Target every post-creation worktree Git mutation explicitly.** `git worktree add`
creates a checkout but does not change the shell's working directory. In a compound
command, a following bare `git cherry-pick`, `merge`, or `commit` still mutates the
original checkout. Run each mutation as `git -C /exact/worktree ...` (or start a new
command with that worktree as its working directory), then verify both branches before
continuing (found 2026-08-04 while combining Voice D2B B0/B1).

<!-- applied-learning: checked-artifacts-must-survive-their-containing-commit -->
<a id="applied-learning-checked-artifacts-must-survive-their-containing-commit"></a>
**Checked artifacts must survive their containing commit.** A generator that
reads the Git index must run only after every source input is staged, and acceptance
must rerun the read-only check after the artifact is committed. Never embed the
containing `HEAD` commit or tree identity in normative bytes: adding the tracked
artifact changes that identity and makes the artifact self-referential. Bind stable
source inputs with scoped manifests and blob digests instead (found 2026-08-13
during PK-K0 acceptance).

<!-- applied-learning: git-pathspec-wildcards-do-not-enforce-directory-depth -->
<a id="applied-learning-git-pathspec-wildcards-do-not-enforce-directory-depth"></a>
**Git pathspec wildcards do not enforce directory depth.** A command such as
`git ls-files 'apps/*/mix.exs'` can include nested fixtures like
`apps/arbor_kernel/priv/.../mix.exs`. When a guard means exactly
`apps/<app>/mix.exs`, filter tracked results by parsed path segments before
treating them as package roots (found 2026-08-14 during K2 app-env validation).

<!-- applied-learning: git-checkout-double-dash-restores-from-the-index-not-head -->
<a id="applied-learning-git-checkout-double-dash-restores-from-the-index-not-head"></a>
**`git checkout -- <file>` restores from the INDEX, not HEAD — which un-does nothing after a blocked commit.** When a pre-commit hook rejects a commit, the changes are still staged. Reaching for `git checkout -- <file>` then faithfully restores the exact content you are trying to discard, and a second edit lands on top of the first: on 2026-08-20 this produced two copies of one skills section and a corrupted applied-learning ownership range (the validator caught it, twice). Use `git restore --source=HEAD --staged --worktree <file>` to actually reset, and verify with a count (`grep -c` for a unique heading) before re-applying rather than assuming the revert worked.

<!-- applied-learning: do-not-inspect-an-active-factory-worktree-after-approving-a-git-mutation -->
<a id="applied-learning-do-not-inspect-an-active-factory-worktree-after-approving-a-git-mutation"></a>
**Do not run Git commands in an active factory worktree after approving a Git mutation.**
Even `git status` can refresh the linked-worktree index and change Git-storage metadata while
the hardened action is completing its post-mutation reads. That correctly trips the TOCTOU
guard after the commit exists, leaving a preserved commit but a failed pipeline. Review the
exact diff before approval, then leave the worktree untouched until the task reaches a terminal
state; inspect the preserved branch only afterward (found 2026-08-21 during reviewed-commit
approval for the TaskArtifacts/readiness fixes).
Even a read-only `git diff --quiet HEAD` can refresh index file-stat metadata.
On 2026-10-04, Root's locked Jido bundle preparation changed only the inventory
row for `deps/jido_sandbox/.git/index`; all 31 mode/blob/stage-zero rows and raw
tracked working blobs still matched the exact locked commit and tree. Use
`GIT_OPTIONAL_LOCKS=0` for authorized metadata-only observations; those reads
preserved the observed index digest. Retain the failed guard and verify the
specific operational change without restoring the old index or exempting the
whole Git directory. This does not authorize inspection during an active mutation.

<!-- applied-learning: verify-retained-candidate-ancestry-before-defining-a-replay-range -->
<a id="applied-learning-verify-retained-candidate-ancestry-before-defining-a-replay-range"></a>
**Verify retained-candidate ancestry before defining a replay range.** A
correction task's recorded base may not be an ancestor of the destination.
Compute the true merge base, enumerate the complete merge-base-to-tip commit
and path manifest, and prove overlap and non-overlap provenance before replay.
Never treat the final correction's base-to-tip range as the full inherited
candidate (found 2026-08-23 while reconstructing the contract-change stack).
For copied qualification trees, name the patch base explicitly and verify every
destination preimage before adoption. A cumulative continuation patch may be
complete relative to an earlier experiment while omitting its SDK/package
prerequisites in main. Separate the host delta from the retained client layout;
never copy test-isolation config or runtime state with source (2026-09-30 human
conversation login adoption).

<!-- applied-learning: preserve-resumable-evidence-outside-os-temporary-roots -->
<a id="applied-learning-preserve-resumable-evidence-outside-os-temporary-roots"></a>
**Preserve resumable evidence outside OS temporary roots.** Use a gitignored
project-local `tmp/` or an explicit persistent artifact root for long-lived candidate
worktrees, source bundles, manifests, and replay notes. An empty surviving `/tmp`
directory is not evidence. Preserve committed candidates with a verified Git bundle
and exact source identities; record missing uncommitted files/logs honestly. Copy
only scoped diagnostics into a private directory, checksum the copies, and leave
other agents' originals untouched. Quote Git-owned ref globs in shell commands so
zsh does not expand or reject them before `git bundle` runs. Reboot persistence is
not an off-device backup or validation acceptance (found 2026-09-07 during G5E
preservation).

<!-- applied-learning: compare-native-and-package-manager-git-before-diagnosing-a-lan-outage -->
<a id="applied-learning-compare-native-and-package-manager-git-before-diagnosing-a-lan-outage"></a>
**Compare native and package-manager Git before diagnosing a LAN outage.** On
2026-09-22, Homebrew Git 2.55.0 failed immediately with `No route to host` while
system curl and `/usr/bin/git` 2.54.0 reached the same Forgejo repository; disabling
proxies did not help. This isolates a client-specific failure, not a dead server.
macOS Local Network permission or process filtering is a hypothesis until verified;
check the responsible terminal app's permission without resetting privacy globally.
Use bounded read-only probes outside the agent sandbox with approval, because a
sandbox network denial is separate evidence. A successful `ls-remote` proves read
connectivity, not push authorization; do not push, restart services, or rewrite the
remote during diagnosis without authorization.

<!-- applied-learning: a-shared-dependency-cache-can-drift-from-the-branch-lock -->
<a id="applied-learning-a-shared-dependency-cache-can-drift-from-the-branch-lock"></a>
**A shared dependency cache can drift from the branch's lock.** Pointing `MIX_DEPS_PATH` at the main checkout's `deps/` assumes that cache matches the branch's `mix.lock`. When the main checkout carries another session's uncommitted lock edit, Mix stops with `lock mismatch: the dependency is out of date` for the changed git deps. Never run `mix deps.get` against the shared cache, because it rewrites another session's checkout. Build a private deps directory instead: symlink every shared dependency except the mismatched ones, `git clone --no-checkout` those from the shared cache, check out the locked revision, and reset `remote.origin.url` to the lock's URL (Mix compares it). Then point `MIX_DEPS_PATH` at that directory (found 2026-10-01 with `membrane_core`/`membrane_portaudio_plugin` while proving the receipt payload fix).
