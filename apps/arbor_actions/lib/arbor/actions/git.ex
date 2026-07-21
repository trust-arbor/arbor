defmodule Arbor.Actions.Git do
  @moduledoc """
  Git repository operations as Jido actions.

  This module provides Jido-compatible actions for common Git operations
  with proper error handling and observability through Arbor.Signals.

  All actions execute Git commands through Arbor.Shell with :basic sandboxing
  to ensure safety while allowing necessary Git operations.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Status` | Get repository status |
  | `Diff` | Show changes between commits or working tree |
  | `Commit` | Create a new commit |
  | `Log` | Show commit history |
  | `Branch` | Create / switch / list branches |
  | `PR` | Open a draft pull request / merge request through the configured SCM |

  ## Examples

      # Get status
      {:ok, result} = Arbor.Actions.Git.Status.run(%{path: "/path/to/repo"}, %{})
      result.is_clean  # => false
      result.modified  # => ["file1.txt", "file2.txt"]

      # Show diff
      {:ok, result} = Arbor.Actions.Git.Diff.run(%{path: "/path/to/repo"}, %{})
      result.diff  # => "diff --git a/file.txt..."

      # Create commit
      {:ok, result} = Arbor.Actions.Git.Commit.run(
        %{path: "/path/to/repo", message: "Fix bug", files: ["file.txt"]},
        %{}
      )

      # Show log
      {:ok, result} = Arbor.Actions.Git.Log.run(
        %{path: "/path/to/repo", limit: 5},
        %{}
      )
  """

  alias Arbor.Shell
  alias Arbor.Common.SafePath

  @storage_authority_key {__MODULE__, :storage_authority}
  @git_deadline_key {__MODULE__, :command_deadline_ms}
  @default_git_timeout_ms 30_000

  @typedoc false
  @type worktree_lstat_identity :: %{
          required(:type) => :directory,
          required(:major_device) => non_neg_integer(),
          required(:minor_device) => non_neg_integer(),
          required(:inode) => non_neg_integer()
        }

  @typedoc false
  @type worktree_registration_identity :: %{
          required(:path) => String.t(),
          optional(:head) => String.t(),
          optional(:branch) => String.t(),
          optional(:detached) => true
        }

  @typedoc false
  @type worktree_removal_identity :: %{
          required(:lstat_identity) => worktree_lstat_identity(),
          required(:worktree_registration) => worktree_registration_identity()
        }

  # Git command defaults - used by all nested action modules
  @doc false
  def git_timeout do
    case Process.get(@git_deadline_key) do
      deadline when is_integer(deadline) ->
        deadline
        |> Kernel.-(System.monotonic_time(:millisecond))
        |> max(1)
        |> min(@default_git_timeout_ms)

      _other ->
        @default_git_timeout_ms
    end
  end

  @doc false
  def git_sandbox, do: :basic

  @git_prefix [
    "--no-pager",
    "--no-replace-objects",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.attributesFile=/dev/null",
    "-c",
    "core.excludesFile=/dev/null",
    "-c",
    "core.pager=cat",
    "-c",
    "pager.diff=false",
    "-c",
    "pager.log=false",
    "-c",
    "diff.external=",
    "-c",
    "commit.gpgSign=false",
    "-c",
    "credential.helper=",
    "-c",
    "gc.auto=0",
    "-c",
    "maintenance.auto=false",
    "-c",
    "protocol.allow=never",
    "-c",
    "submodule.recurse=false"
  ]

  @git_env %{
    "GIT_ALTERNATE_OBJECT_DIRECTORIES" => false,
    "GIT_CONFIG" => false,
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_COUNT" => "0",
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_KEY_0" => false,
    "GIT_CONFIG_PARAMETERS" => false,
    "GIT_CONFIG_SYSTEM" => "/dev/null",
    "GIT_CONFIG_VALUE_0" => false,
    "GIT_COMMON_DIR" => false,
    "GIT_DISCOVERY_ACROSS_FILESYSTEM" => "0",
    "GIT_DIR" => false,
    "GIT_EXEC_PATH" => false,
    "GIT_ATTR_NOSYSTEM" => "1",
    "GIT_EXTERNAL_DIFF" => false,
    "GIT_INDEX_FILE" => false,
    "GIT_NAMESPACE" => false,
    "GIT_OBJECT_DIRECTORY" => false,
    "GIT_PAGER" => "cat",
    "GIT_QUARANTINE_PATH" => false,
    "GIT_REPLACE_REF_BASE" => false,
    "GIT_SHALLOW_FILE" => false,
    "GIT_SSH" => false,
    "GIT_ASKPASS" => false,
    "SSH_ASKPASS" => false,
    "GIT_SSH_COMMAND" => false,
    "GIT_EDITOR" => "false",
    "GIT_SEQUENCE_EDITOR" => "false",
    "GIT_TERMINAL_PROMPT" => "0",
    "GIT_WORK_TREE" => false
  }

  @unsafe_config_pattern "^(include\\.|includeif\\.|filter\\..*\\.(clean|smudge|process)$|diff\\..*\\.(command|textconv)$|diff\\.external$|merge\\..*\\.driver$|credential\\.helper$|core\\.(attributesfile|editor|excludesfile|hookspath|fsmonitor|pager|sshcommand)$|pager\\.|interactive\\.difffilter$|maintenance\\.|submodule\\..*\\.update$|commit\\.gpgsign$|gpg\\.program$|sequence\\.editor$)"

  @doc false
  def execute(path, args) when is_binary(path) and is_list(args) do
    with :ok <- validate_git_args(args),
         {:ok, authorized_root} <- authorized_root(path),
         storage_roots <- storage_roots(authorized_root),
         {:ok, storage_guard} <- validate_repository_storage(authorized_root, storage_roots),
         :ok <- reject_configured_helpers(authorized_root),
         :ok <- verify_storage_guard(storage_guard) do
      execute_without_audit(authorized_root, args)
    end
  end

  def execute(_path, _args), do: {:error, :invalid_git_execution}

  # Cleanup authority includes caller-captured filesystem and Git-registration
  # identity. Carrying both through this final destructive facade closes the
  # validation-to-Git gap; there is deliberately no unbound removal API.
  # A malicious same-UID double-swap between path checks remains outside the
  # guarantees available through portable BEAM filesystem APIs.
  @doc false
  @spec remove_worktree(String.t(), String.t(), worktree_removal_identity()) ::
          :ok | {:error, term()}
  def remove_worktree(repository_root, worktree_root, expected_identity)
      when is_binary(repository_root) and is_binary(worktree_root) do
    with :ok <- validate_worktree_removal_identity(expected_identity) do
      do_remove_worktree(repository_root, worktree_root, expected_identity)
    end
  end

  def remove_worktree(_repository_root, _worktree_root, _expected_identity),
    do: {:error, :invalid_git_worktree_removal}

  @doc false
  @spec remove_worktree(
          String.t(),
          String.t(),
          worktree_removal_identity(),
          pos_integer()
        ) :: :ok | {:error, term()}
  def remove_worktree(repository_root, worktree_root, expected_identity, timeout_ms)
      when is_binary(repository_root) and is_binary(worktree_root) and is_integer(timeout_ms) and
             timeout_ms > 0 and timeout_ms <= @default_git_timeout_ms do
    with_command_deadline(timeout_ms, fn ->
      remove_worktree(repository_root, worktree_root, expected_identity)
    end)
  end

  def remove_worktree(_repository_root, _worktree_root, _expected_identity, _timeout_ms),
    do: {:error, :invalid_git_worktree_removal}

  @doc false
  @spec worktree_registration(String.t(), String.t()) ::
          {:ok, worktree_registration_identity() | nil} | {:error, term()}
  def worktree_registration(repository_root, worktree_root)
      when is_binary(repository_root) and is_binary(worktree_root) do
    with {:ok, expected_path} <- canonical_comparison_path(worktree_root),
         {:ok, registrations} <- worktree_inventory(repository_root) do
      {:ok, Enum.find(registrations, &(&1.path == expected_path))}
    end
  end

  def worktree_registration(_repository_root, _worktree_root),
    do: {:error, :invalid_git_worktree_lookup}

  @doc false
  @spec worktree_registration(String.t(), String.t(), pos_integer()) ::
          {:ok, worktree_registration_identity() | nil} | {:error, term()}
  def worktree_registration(repository_root, worktree_root, timeout_ms)
      when is_binary(repository_root) and is_binary(worktree_root) and is_integer(timeout_ms) and
             timeout_ms > 0 and timeout_ms <= @default_git_timeout_ms do
    with_command_deadline(timeout_ms, fn ->
      worktree_registration(repository_root, worktree_root)
    end)
  end

  def worktree_registration(_repository_root, _worktree_root, _timeout_ms),
    do: {:error, :invalid_git_worktree_lookup}

  @doc false
  @spec worktree_for_branch(String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def worktree_for_branch(repository_root, branch)
      when is_binary(repository_root) and is_binary(branch) do
    with :ok <- validate_branch_name(branch),
         {:ok, registrations} <- worktree_inventory(repository_root) do
      case Enum.find(registrations, &(&1[:branch] == branch)) do
        %{path: path} -> {:ok, path}
        nil -> {:ok, nil}
      end
    end
  end

  def worktree_for_branch(_repository_root, _branch),
    do: {:error, :invalid_git_worktree_lookup}

  # Structured exact-ref observation for a local branch. This is the single
  # locale-independent source of truth for branch settlement decisions. It
  # distinguishes a present ref's OID from definitive absence and fails closed
  # on every git error, corrupt ref, or malformed/warning output — a missing
  # ref is reported only when git gives the canonical absent signal (exit 0
  # with empty stdout from `for-each-ref` with an exact ref). Callers must
  # never infer absence from a nonzero exit or from localized stderr/stdout
  # text.
  @doc false
  @spec observe_branch_ref(String.t(), String.t()) ::
          {:ok, {:present, String.t()} | :absent} | {:error, term()}
  def observe_branch_ref(repository_root, branch)
      when is_binary(repository_root) and is_binary(branch) do
    with :ok <- validate_branch_name(branch),
         {:ok, canonical_repo} <- authorized_root(repository_root) do
      read_branch_ref_observation(canonical_repo, "refs/heads/" <> branch)
    end
  end

  def observe_branch_ref(_repository_root, _branch),
    do: {:error, :invalid_git_branch_observation}

  # Atomically delete a local branch ref when it still points at `expected_oid`.
  #
  # Safety properties:
  # * uses `git update-ref -d` with the expected old OID (never `branch -D`)
  # * rejects branches currently checked out in any worktree (pre-delete check)
  # * after a successful CAS delete, revalidates worktree registrations: if a
  #   checkout race is observed (a new worktree checked out the branch between
  #   the precheck and the delete, leaving the ref retired out from under a live
  #   worktree HEAD), the exact expected ref is CAS-restored against absence and
  #   an explicit `:branch_checked_out_race` error is returned. The restore
  #   verifies the exact OID and the checkout state and never overwrites a
  #   concurrent replacement ref. This is conservative detection/repair, not
  #   full external atomicity.
  # * verifies the ref is absent after a successful delete (post-delete check)
  # * is idempotent when the ref is already absent
  # * fails closed on expected-OID races (`:branch_ref_oid_mismatch`)
  # * never parses localized update-ref text: after an `update-ref` failure it
  #   re-reads the ref through `observe_branch_ref/2` and classifies absence as
  #   idempotent success, a different OID as mismatch, and the same OID as an
  #   operational failure.
  @doc false
  @spec delete_branch_ref(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_branch_ref(repository_root, branch, expected_oid)
      when is_binary(repository_root) and is_binary(branch) and is_binary(expected_oid) do
    expected_oid = expected_oid |> String.trim() |> String.downcase()

    with :ok <- validate_branch_name(branch),
         :ok <- validate_full_oid(expected_oid),
         {:ok, canonical_repo} <- authorized_root(repository_root) do
      case observe_branch_ref(canonical_repo, branch) do
        {:ok, :absent} ->
          :ok

        {:ok, {:present, ^expected_oid}} ->
          with :ok <- reject_checked_out_branch(canonical_repo, branch),
               :ok <- run_pre_delete_test_hook(canonical_repo, branch),
               :ok <- execute_update_ref_delete(canonical_repo, branch, expected_oid) do
            # Post-delete revalidation: verify absence AND check for a checkout
            # race that occurred between the precheck and the CAS delete.
            verify_after_delete(canonical_repo, branch, expected_oid)
          end

        {:ok, {:present, _other_oid}} ->
          {:error, :branch_ref_oid_mismatch}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def delete_branch_ref(_repository_root, _branch, _expected_oid),
    do: {:error, :invalid_git_branch_ref_delete}

  # Identity-bound hidden evidence-ref archive for the managed coding branch
  # lifecycle.
  #
  # Archives an exact local branch tip to a deterministic Arbor-owned hidden
  # ref outside refs/heads/, keyed by exact nonblank bounded task_id and
  # workspace_id. The caller cannot reach arbitrary refs — only the computed
  # evidence ref for these inputs is mutated, and only via compare-and-create
  # against absence.
  #
  # Semantics:
  # * before first creation: require the local branch to exist at expected_oid
  # * create with CAS against absence (`update-ref <hidden> <oid> <zero>`);
  #   never overwrite an existing ref
  # * idempotent replay: if the evidence ref already exists at expected_oid,
  #   succeed even if the temporary local branch has since disappeared
  # * if the evidence ref exists at another OID: stable mismatch error
  # * if neither branch nor archive proves expected_oid: fail
  # * SHA-1 (40 hex) and SHA-256 (64 hex) OIDs are both supported; the zero
  #   old-OID width is derived from expected_oid
  # * the OID must resolve to a commit object (cat-file -t)
  # * the exact hidden ref is verified after creation; warnings or malformed
  #   git output fail closed
  @evidence_ref_namespace "refs/arbor/evidence"
  # Distinct durable-lifecycle bounds so every admitted record remains
  # archivable: task_id up to 256 bytes, workspace_id up to 128 bytes. These
  # match the existing durable lifecycle limits rather than a single arbitrary
  # ceiling; the raw opaque bytes are preserved for digest derivation after
  # nonblank/UTF-8/NUL validation (no trimming or normalization).
  @max_task_id_bytes 256
  @max_workspace_id_bytes 128

  @doc false
  @spec archive_branch_evidence_ref(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, %{hidden_ref: String.t()}} | {:error, term()}
  def archive_branch_evidence_ref(repository_root, branch, task_id, workspace_id, expected_oid)
      when is_binary(repository_root) and is_binary(branch) and is_binary(task_id) and
             is_binary(workspace_id) and is_binary(expected_oid) do
    expected_oid = expected_oid |> String.trim() |> String.downcase()

    with :ok <- validate_branch_name(branch),
         :ok <- validate_full_oid(expected_oid),
         :ok <- validate_identity_id(task_id, @max_task_id_bytes),
         :ok <- validate_identity_id(workspace_id, @max_workspace_id_bytes),
         {:ok, canonical_repo} <- authorized_root(repository_root),
         :ok <- verify_commit_oid(canonical_repo, expected_oid),
         hidden_ref = evidence_ref_for(task_id, workspace_id),
         :ok <- validate_evidence_ref_name(hidden_ref),
         {:ok, archive_state} <- read_branch_ref_observation(canonical_repo, hidden_ref) do
      archive_branch_evidence(canonical_repo, branch, expected_oid, hidden_ref, archive_state)
    end
  end

  def archive_branch_evidence_ref(
        _repository_root,
        _branch,
        _task_id,
        _workspace_id,
        _expected_oid
      ),
      do: {:error, :invalid_git_evidence_archive}

  # Validate an identity-bound ID against its distinct durable-lifecycle byte
  # limit. The raw opaque bytes are preserved for digest derivation (no
  # trimming/normalization of the value itself); only nonblank/UTF-8/NUL and
  # the bound-specific byte ceiling are enforced.
  defp validate_identity_id(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    cond do
      String.trim(value) == "" ->
        {:error, :invalid_git_evidence_identity}

      not String.valid?(value) ->
        {:error, :invalid_git_evidence_identity}

      String.contains?(value, <<0>>) ->
        {:error, :invalid_git_evidence_identity}

      byte_size(value) > max_bytes ->
        {:error, :invalid_git_evidence_identity}

      true ->
        :ok
    end
  end

  defp validate_identity_id(_value, _max_bytes), do: {:error, :invalid_git_evidence_identity}

  # Deterministic, caller-proof hidden-ref path. Components are SHA-256 hex of
  # the raw task_id / workspace_id so caller text cannot escape the namespace,
  # alias another identity, or violate git ref component rules.
  defp evidence_ref_for(task_id, workspace_id) do
    task_digest = evidence_digest(task_id)
    workspace_digest = evidence_digest(workspace_id)

    "#{@evidence_ref_namespace}/#{workspace_digest}/#{task_digest}"
  end

  defp evidence_digest(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  # Belt-and-suspenders: confirm the computed ref stays inside the Arbor
  # evidence namespace with exactly two 64-hex digest components. The digest
  # derivation already guarantees this; the structural check guards against
  # future refactors that might break the invariant.
  defp validate_evidence_ref_name(ref) do
    namespace_prefix = @evidence_ref_namespace <> "/"
    components = String.split(ref, "/")

    with true <- String.starts_with?(ref, namespace_prefix),
         false <- String.contains?(ref, ["..", "//", "\\", <<0>>]),
         ["refs", "arbor", "evidence", workspace_digest, task_digest] <- components,
         true <- byte_size(workspace_digest) == 64,
         true <- byte_size(task_digest) == 64,
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, workspace_digest),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, task_digest) do
      :ok
    else
      _other -> {:error, {:invalid_git_evidence_ref, ref}}
    end
  end

  # Confirm the OID resolves to a commit object via structured cat-file output.
  # Exit 0 with exactly "commit" on stdout (trimmed) and no stderr is the sole
  # acceptance signal; any warning, different type, or nonzero exit fails closed.
  defp verify_commit_oid(repository_root, oid) do
    case execute(repository_root, ["cat-file", "-t", oid]) do
      {:ok, %{exit_code: 0, stdout: stdout, stderr: stderr}} ->
        trimmed_stderr = String.trim(stderr)
        trimmed_stdout = String.trim(stdout)

        cond do
          trimmed_stderr != "" ->
            {:error, {:git_evidence_oid_warning, trimmed_stderr}}

          trimmed_stdout != "commit" ->
            {:error, {:git_evidence_oid_not_commit, trimmed_stdout}}

          true ->
            :ok
        end

      {:ok, result} ->
        {:error, {:git_evidence_oid_lookup_failed, Map.get(result, :exit_code)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp archive_branch_evidence(
         repository_root,
         branch,
         expected_oid,
         hidden_ref,
         archive_state
       ) do
    case archive_state do
      {:present, ^expected_oid} ->
        # Idempotent replay: the archive already proves the expected OID.
        # Succeed without re-verifying the local branch — the proof is durable
        # and the temporary branch may have already been retired.
        {:ok, %{hidden_ref: hidden_ref}}

      {:present, _other_oid} ->
        # The archive exists at a different OID — never overwrite.
        {:error, :evidence_ref_oid_mismatch}

      :absent ->
        with :ok <- require_branch_at_oid(repository_root, branch, expected_oid),
             :ok <- run_pre_evidence_cas_test_hook(repository_root, hidden_ref, expected_oid),
             :ok <- create_evidence_ref_cas(repository_root, hidden_ref, expected_oid),
             :ok <- verify_evidence_ref(repository_root, hidden_ref, expected_oid) do
          {:ok, %{hidden_ref: hidden_ref}}
        end
    end
  end

  defp require_branch_at_oid(repository_root, branch, expected_oid) do
    case observe_branch_ref(repository_root, branch) do
      {:ok, {:present, ^expected_oid}} ->
        :ok

      {:ok, {:present, _other_oid}} ->
        {:error, :branch_ref_oid_mismatch}

      {:ok, :absent} ->
        {:error, :branch_ref_absent}

      {:error, _reason} = error ->
        error
    end
  end

  # Deterministic test injection point precisely between the branch-at-OID
  # precheck and the CAS-create. Production builds compile an unconditional
  # no-op so callers cannot alter a security observation through the process
  # dictionary.
  if Mix.env() == :test do
    defp run_pre_evidence_cas_test_hook(repository_root, hidden_ref, expected_oid) do
      case Process.delete({__MODULE__, :pre_evidence_cas_hook}) do
        callback when is_function(callback, 3) ->
          callback.(repository_root, hidden_ref, expected_oid)
          :ok

        _other ->
          :ok
      end
    end
  else
    defp run_pre_evidence_cas_test_hook(_repository_root, _hidden_ref, _expected_oid), do: :ok
  end

  # Compare-and-create the hidden evidence ref against absence. The zero
  # old-OID width is derived from expected_oid so SHA-1 (40 hex) and SHA-256
  # (64 hex) repositories are both handled. A nonzero exit means the ref is no
  # longer absent; classify without overwriting.
  defp create_evidence_ref_cas(repository_root, hidden_ref, expected_oid) do
    zero = String.duplicate("0", String.length(expected_oid))

    repository_root
    |> execute(["update-ref", hidden_ref, expected_oid, zero])
    |> augment_dirty_output(:update_ref_evidence)
    |> case do
      {:ok, %{exit_code: 0} = result} ->
        if clean_success?(result),
          do: :ok,
          else: {:error, :git_evidence_create_dirty_success}

      {:ok, result} ->
        classify_evidence_cas_failure(repository_root, hidden_ref, expected_oid, result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_evidence_cas_failure(repository_root, hidden_ref, expected_oid, result) do
    case read_branch_ref_observation(repository_root, hidden_ref) do
      {:ok, {:present, ^expected_oid}} ->
        # A concurrent writer archived the same OID. Idempotent success.
        :ok

      {:ok, {:present, _other_oid}} ->
        # A concurrent writer archived a different OID — never replaced.
        {:error, :evidence_ref_oid_mismatch}

      {:ok, :absent} ->
        # Precondition failed and the ref is still absent — operational failure.
        {:error, {:git_evidence_create_failed, Map.get(result, :exit_code)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_evidence_ref(repository_root, hidden_ref, expected_oid) do
    case read_branch_ref_observation(repository_root, hidden_ref) do
      {:ok, {:present, ^expected_oid}} ->
        :ok

      {:ok, {:present, _other_oid}} ->
        {:error, :evidence_ref_oid_mismatch}

      {:ok, :absent} ->
        {:error, :evidence_ref_lost_after_create}

      {:error, _reason} = error ->
        error
    end
  end

  defp do_remove_worktree(repository_root, worktree_root, expected_identity) do
    with {:ok, canonical_repository} <- authorized_root(repository_root),
         {:ok, canonical_worktree} <- authorized_root(worktree_root),
         :ok <- reject_primary_worktree(canonical_repository, canonical_worktree),
         :ok <-
           require_worktree_lstat_identity(
             canonical_worktree,
             expected_identity.lstat_identity
           ) do
      with_storage_authority(canonical_repository, canonical_worktree, fn ->
        remove_bound_worktree(canonical_repository, canonical_worktree, expected_identity)
      end)
    end
  end

  defp validate_full_oid(oid) when is_binary(oid) do
    if Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, oid) do
      :ok
    else
      {:error, :invalid_git_oid}
    end
  end

  defp validate_full_oid(_), do: {:error, :invalid_git_oid}

  defp reject_checked_out_branch(repository_root, branch) do
    case worktree_for_branch(repository_root, branch) do
      {:ok, nil} -> :ok
      {:ok, _path} -> {:error, :branch_checked_out}
      {:error, reason} -> {:error, reason}
    end
  end

  # Deterministic test injection points for the two checkout-race windows.
  # Production builds compile unconditional no-ops, so callers cannot alter a
  # security observation through a process-dictionary callback.
  if Mix.env() == :test do
    defp run_pre_delete_test_hook(repository_root, branch) do
      case Process.delete({__MODULE__, :pre_delete_branch_ref_hook}) do
        callback when is_function(callback, 2) ->
          callback.(repository_root, branch)
          :ok

        _other ->
          :ok
      end
    end

    defp run_pre_confirm_restore_test_hook(repository_root, branch) do
      case Process.delete({__MODULE__, :pre_confirm_restore_hook}) do
        callback when is_function(callback, 2) ->
          callback.(repository_root, branch)
          :ok

        _other ->
          :ok
      end
    end
  else
    defp run_pre_delete_test_hook(_repository_root, _branch), do: :ok
    defp run_pre_confirm_restore_test_hook(_repository_root, _branch), do: :ok
  end

  # Structured exact-ref observation via `for-each-ref` for locale-independent,
  # fail-closed branch presence/absence detection. The command uses
  # `--count=1` with exact ref matching (not a prefix glob) so that:
  #
  #   * exit 0 with empty stdout = definitive absence (single canonical signal)
  #   * exit 0 with one line = the exact ref name and a valid OID
  #   * exit 0 with >1 line = extra/duplicate records, rejected
  #   * any nonzero exit = error (never absence)
  #   * any stderr = warning, rejected
  #   * malformed OID, truncated line, extra fields, wrong refname prefix = rejected
  #
  # Callers must never infer absence from a nonzero exit, from stderr text,
  # from multiple records, or from a similarly-prefixed but non-exact ref.
  defp read_branch_ref_observation(repository_root, full_ref) do
    case execute(repository_root, [
           "for-each-ref",
           "--count=1",
           "--format=%(refname) %(objectname)",
           full_ref
         ]) do
      {:ok, %{exit_code: 0, stdout: stdout, stderr: stderr}} ->
        trimmed_stderr = String.trim(stderr)
        trimmed_stdout = String.trim(stdout)

        cond do
          trimmed_stderr != "" ->
            {:error, {:git_branch_ref_warning, trimmed_stderr}}

          trimmed_stdout == "" ->
            {:ok, :absent}

          true ->
            parse_for_each_ref_output(trimmed_stdout, full_ref)
        end

      {:ok, result} ->
        {:error,
         {:git_for_each_ref_failed, Map.get(result, :exit_code),
          Map.get(result, :stderr) || Map.get(result, :stdout)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse exactly one record from for-each-ref output. The record must contain
  # the exact full ref name (not a prefix match) followed by exactly one valid
  # hex OID. Reject multiple records, wrong refnames, truncated or extra fields.
  defp parse_for_each_ref_output(output, expected_ref) do
    lines = String.split(output, "\n", trim: true)

    case lines do
      [line] ->
        case String.split(line, " ", parts: 2) do
          [^expected_ref, oid_candidate] ->
            oid = String.downcase(String.trim(oid_candidate))

            cond do
              oid == "" ->
                {:error, :git_branch_ref_empty_oid}

              String.contains?(oid, " ") ->
                {:error, :git_branch_ref_extra_fields}

              match?(:ok, validate_full_oid(oid)) ->
                {:ok, {:present, oid}}

              true ->
                {:error, :invalid_git_oid}
            end

          [other_ref, _] ->
            # Similarly prefixed but non-exact ref (e.g. refs/heads/foo vs
            # refs/heads/foobar).  This is a strict-exact observation; a
            # non-exact match fails closed rather than silently treating it
            # as absent.
            {:error, {:git_branch_ref_non_exact_match, other_ref}}

          _ ->
            {:error, :git_branch_ref_malformed_output}
        end

      [] ->
        {:error, :git_branch_ref_empty_oid}

      _multiple ->
        {:error, {:git_branch_ref_extra_records, length(lines)}}
    end
  end

  # `git update-ref` produces no stdout/stderr on a clean success.  Exit 0
  # with unexpected output must surface a stable explicit error rather than
  # being reclassified as ordinary idempotent success.
  defp clean_success?(%{exit_code: 0, stdout: "", stderr: ""}), do: true

  defp clean_success?(_), do: false

  # Test-build-only seam: a one-shot process flag can append synthetic
  # stdout/stderr to the REAL update-ref result.  This can only force
  # fail-closed (dirty output on an exit-0 result triggers the clean-success
  # rejection); it can never force false success or alter a real failure.
  # Production builds compile a no-op so the injection surface does not exist.
  if Mix.env() == :test do
    defp augment_dirty_output(result, tag) do
      injection = Process.delete({__MODULE__, {tag, :dirty_output}})

      case {result, injection} do
        {{:ok, %{exit_code: 0, stdout: stdout, stderr: stderr} = command_result},
         {extra_stdout, extra_stderr}}
        when is_binary(stdout) and is_binary(stderr) and is_binary(extra_stdout) and
               is_binary(extra_stderr) ->
          {:ok,
           %{
             command_result
             | stdout: stdout <> extra_stdout,
               stderr: stderr <> extra_stderr
           }}

        _other ->
          result
      end
    end
  else
    defp augment_dirty_output(result, _tag), do: result
  end

  # Run `git update-ref -d <ref> <expected_oid>` and classify the result without
  # parsing localized stderr/stdout text. On a nonzero exit, re-read the ref
  # through the structured observer: absence is idempotent success (the desired
  # state was reached), a different OID is a CAS mismatch, and the same OID is
  # an operational failure that callers may retry.
  #
  # Exit 0 with dirty output is rejected — `update-ref` on success is silent;
  # unexpected output signals a malformed or warning state that must not be
  # silently treated as success.
  defp execute_update_ref_delete(repository_root, branch, expected_oid) do
    ref = "refs/heads/" <> branch

    result =
      execute(repository_root, ["update-ref", "-d", ref, expected_oid])
      |> augment_dirty_output(:update_ref_delete)

    case result do
      {:ok, %{exit_code: 0} = r} ->
        if clean_success?(r),
          do: :ok,
          else: {:error, :git_update_ref_dirty_success}

      {:ok, result} ->
        classify_update_ref_failure(repository_root, branch, expected_oid, result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_update_ref_failure(repository_root, branch, expected_oid, result) do
    case observe_branch_ref(repository_root, branch) do
      {:ok, :absent} ->
        :ok

      {:ok, {:present, oid}} when oid == expected_oid ->
        # Ref is unchanged after a failed update-ref: operational failure.
        {:error, {:git_update_ref_delete_failed, Map.get(result, :exit_code), expected_oid}}

      {:ok, {:present, _moved_oid}} ->
        # The live OID no longer matches the expected CAS value.
        {:error, :branch_ref_oid_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  # Post-delete verification: confirm the ref is absent AND detect a checkout
  # race that occurred between the pre-delete check and the CAS delete. When
  # a race is detected, the exact expected ref is CAS-restored and an explicit
  # `:branch_checked_out_race` error is returned — the caller sees residue,
  # never a false claim of deletion.
  #
  # This is conservative detection/repair, not full external atomicity. The
  # window is: between `reject_checked_out_branch` and `update-ref -d`, a
  # new worktree may have checked out the branch. The CAS restore ensures the
  # ref is not silently lost.
  defp verify_after_delete(repository_root, branch, expected_oid) do
    case observe_branch_ref(repository_root, branch) do
      {:ok, :absent} ->
        # Ref absent after the CAS delete. Re-probe the worktree inventory: a
        # checkout that landed between the precheck and the delete leaves a
        # registered worktree whose HEAD now points at a retired ref. That is
        # the race this boundary must close — CAS-restore the exact expected
        # ref (compare-and-create against absence) so the branch is not
        # silently lost, then surface explicit residue.
        case worktree_for_branch(repository_root, branch) do
          {:ok, nil} ->
            :ok

          {:ok, _path} ->
            restore_and_report_checkout_race(repository_root, branch, expected_oid)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, {:present, ^expected_oid}} ->
        # The ref is still at the expected OID after delete — a checkout
        # race CAS-restored it, or the delete silently failed. Verify the
        # race by checking if the branch is now checked out.
        case worktree_for_branch(repository_root, branch) do
          {:ok, nil} ->
            # Ref present but not checked out — operational failure.
            {:error, :branch_ref_still_present}

          {:ok, _path} ->
            # Checkout race detected. The ref was restored by the race
            # window. Report explicit race/residue.
            {:error, :branch_checked_out_race}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, {:present, _different_oid}} ->
        # Ref points to a different OID after delete — something else moved
        # it. This is an unexpected state; report as residue.
        {:error, :branch_ref_oid_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # CAS-restore `refs/heads/<branch>` to exactly `expected_oid` only if the ref
  # is currently absent (zero oldvalue precondition), then verify the final
  # ref state and the checkout. Never overwrites a concurrent replacement ref:
  # a nonzero CAS exit means the ref is no longer absent, and the follow-up
  # observation decides whether the existing value is acceptable or residue.
  # The zero old-OID width is derived from `expected_oid` so SHA-1 (40 hex)
  # and SHA-256 (64 hex) repositories are both handled correctly.
  defp restore_and_report_checkout_race(repository_root, branch, expected_oid) do
    ref = "refs/heads/" <> branch
    zero = String.duplicate("0", String.length(expected_oid))

    cas_outcome =
      execute(repository_root, ["update-ref", ref, expected_oid, zero])
      |> augment_dirty_output(:update_ref_restore)
      |> case do
        {:ok, %{exit_code: 0} = result} ->
          if clean_success?(result),
            do: :cas_succeeded,
            else: :dirty_success

        {:ok, result} ->
          {:cas_precondition_failed, Map.get(result, :exit_code)}

        {:error, reason} ->
          {:restore_error, reason}
      end

    # Test seam: simulate the racing checkout vanishing (concurrent worktree
    # remove) between the CAS-restore above and the confirm verification below.
    # No-op in production.
    :ok = run_pre_confirm_restore_test_hook(repository_root, branch)

    case confirm_race_restore(repository_root, branch, expected_oid, cas_outcome) do
      :ok ->
        {:error, :branch_checked_out_race}

      {:error, _reason} = error ->
        error
    end
  end

  # Verify the post-restore ref state. The checkout that triggered the race is
  # expected to still hold the branch; confirm both the exact OID and the
  # registered worktree so callers see honest residue, never a silent loss.
  #
  # The nil-checkout case MUST come before the surviving-path catch-all: a nil
  # worktree means the racing checkout vanished after the restore, which is
  # explicit residue (:branch_ref_restore_checkout_lost), NOT a successful race
  # confirmation. Matching {:ok, _path} first would shadow nil and silently
  # treat a lost checkout as a surviving one.
  defp confirm_race_restore(repository_root, branch, expected_oid, cas_outcome) do
    case observe_branch_ref(repository_root, branch) do
      {:ok, {:present, ^expected_oid}} ->
        case worktree_for_branch(repository_root, branch) do
          {:ok, nil} ->
            # Ref restored but the checkout vanished — honest residue.
            {:error, :branch_ref_restore_checkout_lost}

          {:ok, _path} ->
            if cas_outcome == :dirty_success,
              do: {:error, :git_update_ref_restore_dirty_success},
              else: :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, {:present, _other_oid}} ->
        # A concurrent replacement ref exists — never overwritten.
        {:error, :branch_ref_restore_ref_replaced}

      {:ok, :absent} ->
        case cas_outcome do
          :cas_succeeded ->
            # CAS reported success but the ref is absent — raced away again.
            {:error, :branch_ref_restore_race}

          {:cas_precondition_failed, _exit} ->
            # Precondition failed and ref is absent — unexpected concurrent
            # retirement. Surface as residue.
            {:error, :branch_ref_restore_race}

          :dirty_success ->
            # CAS reported exit 0 with unexpected output — never silently
            # accept; surface explicit residue.
            {:error, :git_update_ref_restore_dirty_success}

          {:restore_error, reason} ->
            # The restore command itself errored and the ref is absent.
            # Surface explicit residue rather than silently losing the ref.
            {:error, {:branch_ref_restore_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:branch_ref_restore_failed, cas_outcome, reason}}
    end
  end

  @doc false
  def with_storage_authority(repository_root, worktree_root, fun)
      when is_binary(repository_root) and is_binary(worktree_root) and is_function(fun, 0) do
    with {:ok, canonical_repository} <- authorized_root(repository_root),
         {:ok, canonical_worktree} <- authorized_root(worktree_root) do
      previous = Process.get(@storage_authority_key)

      authority = %{
        owner: self(),
        reference: make_ref(),
        repository_root: canonical_repository,
        worktree_root: canonical_worktree
      }

      Process.put(@storage_authority_key, authority)

      try do
        fun.()
      after
        restore_storage_authority(previous)
      end
    end
  end

  def with_storage_authority(_repository_root, _worktree_root, _fun),
    do: {:error, :invalid_git_storage_authority}

  @doc false
  def validate_ref(ref) when is_binary(ref) do
    components = String.split(ref, "/")

    valid? =
      String.valid?(ref) and byte_size(ref) in 1..1024 and
        Regex.match?(~r/\A(?:HEAD|[A-Za-z0-9][A-Za-z0-9._\/-]*)(?:[~^][0-9]*)*\z/, ref) and
        not String.starts_with?(ref, "-") and
        not String.contains?(ref, ["..", "//", "@{", "\\", <<0>>]) and
        not String.ends_with?(ref, ["/", ".", ".lock"]) and
        Enum.all?(components, &valid_ref_component?/1)

    if valid?, do: :ok, else: {:error, {:invalid_git_ref, ref}}
  end

  def validate_ref(ref), do: {:error, {:invalid_git_ref, ref}}

  @doc false
  def validate_branch_name(name) when is_binary(name) do
    with :ok <- validate_ref(name),
         false <- String.contains?(name, ["~", "^"]),
         false <- name == "HEAD" do
      :ok
    else
      _ -> {:error, {:invalid_git_branch, name}}
    end
  end

  def validate_branch_name(name), do: {:error, {:invalid_git_branch, name}}

  @doc false
  def validate_repo_path(path) when is_binary(path) do
    components = Path.split(path)

    valid? =
      path != "" and String.valid?(path) and not String.contains?(path, <<0>>) and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, path) and Path.type(path) == :relative and
        Enum.all?(components, &(&1 not in ["", ".", ".."]))

    if valid?, do: :ok, else: {:error, {:invalid_git_path, path}}
  end

  def validate_repo_path(path), do: {:error, {:invalid_git_path, path}}

  defp valid_ref_component?(component) do
    component != "" and not String.starts_with?(component, ".") and
      not String.ends_with?(component, ".lock")
  end

  defp validate_git_args([command | rest])
       when is_binary(command) and command != "" and is_list(rest) do
    dangerous_scope? =
      Enum.any?([command | rest], fn
        "-C" ->
          true

        "--git-dir" ->
          true

        "--absolute-git-dir" ->
          true

        "--git-common-dir" ->
          true

        "--work-tree" ->
          true

        "--namespace" ->
          true

        "--config-env" ->
          true

        argument when is_binary(argument) ->
          String.starts_with?(argument, [
            "--git-dir=",
            "--absolute-git-dir=",
            "--git-common-dir=",
            "--work-tree=",
            "--namespace=",
            "--config-env="
          ])

        _other ->
          true
      end)

    valid_strings? =
      Enum.all?([command | rest], &(is_binary(&1) and not String.contains?(&1, <<0>>)))

    if valid_strings? and not String.starts_with?(command, "-") and not dangerous_scope?,
      do: :ok,
      else: {:error, :invalid_git_execution_scope}
  end

  defp validate_git_args(_args), do: {:error, :invalid_git_execution_scope}

  defp authorized_root(path) do
    case SafePath.resolve_real(path) do
      {:ok, canonical} when is_binary(canonical) ->
        if File.dir?(canonical), do: {:ok, canonical}, else: {:error, :invalid_git_repository}

      _other ->
        {:error, :invalid_git_repository}
    end
  end

  defp validate_repository_storage(authorized_root, storage_roots) do
    with {:ok, worktree} <- query_repository_path(authorized_root, "--show-toplevel"),
         {:ok, git_dir} <- query_repository_path(authorized_root, "--absolute-git-dir"),
         {:ok, common_dir} <- query_repository_path(authorized_root, "--git-common-dir"),
         {:ok, object_dir} <- query_repository_path(authorized_root, ["--git-path", "objects"]),
         :ok <- require_authorized_storage(:worktree, worktree, [authorized_root]),
         :ok <- require_authorized_storage(:git_dir, git_dir, storage_roots),
         :ok <- require_authorized_storage(:common_dir, common_dir, storage_roots),
         :ok <- require_authorized_storage(:object_dir, object_dir, storage_roots),
         :ok <- reject_object_alternates(object_dir),
         {:ok, identities} <-
           capture_storage_identities(
             storage_roots ++ [worktree, git_dir, common_dir, object_dir]
           ) do
      {:ok, %{authorized_root: authorized_root, identities: identities}}
    end
  end

  defp query_repository_path(authorized_root, option) do
    option_args = List.wrap(option)
    args = ["rev-parse", "--path-format=absolute"] ++ option_args

    case execute_without_audit(authorized_root, args) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        path = String.trim_trailing(output, "\n")

        with true <- path != "" and not String.contains?(path, ["\n", "\r", <<0>>]),
             {:ok, canonical} <- SafePath.resolve_real(path) do
          {:ok, canonical}
        else
          _other -> {:error, {:invalid_git_storage_path, option, output}}
        end

      {:ok, result} ->
        {:error, {:git_storage_validation_failed, option, result.exit_code, result.stdout}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_authorized_storage(kind, path, authorized_roots) do
    if Enum.any?(authorized_roots, &within_root?(path, &1)) do
      :ok
    else
      reason =
        if kind == :worktree,
          do: :git_worktree_outside_authorized_root,
          else: :git_storage_outside_authorized_root

      {:error, {reason, kind, path}}
    end
  end

  defp within_root?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp storage_roots(authorized_root) do
    case Process.get(@storage_authority_key) do
      %{
        owner: owner,
        reference: reference,
        repository_root: repository_root,
        worktree_root: ^authorized_root
      }
      when owner == self() and is_reference(reference) and is_binary(repository_root) ->
        Enum.uniq([authorized_root, repository_root])

      _other ->
        [authorized_root]
    end
  end

  defp restore_storage_authority(nil), do: Process.delete(@storage_authority_key)

  defp restore_storage_authority(previous),
    do: Process.put(@storage_authority_key, previous)

  defp reject_object_alternates(object_dir) do
    Enum.reduce_while(["alternates", "http-alternates"], :ok, fn name, :ok ->
      path = Path.join([object_dir, "info", name])

      case File.lstat(path) do
        {:error, :enoent} ->
          {:cont, :ok}

        {:ok, %File.Stat{type: :regular}} ->
          case File.read(path) do
            {:ok, contents} ->
              if String.trim(contents) == "",
                do: {:cont, :ok},
                else: {:halt, {:error, {:git_object_alternates_forbidden, path}}}

            {:error, reason} ->
              {:halt, {:error, {:git_object_alternates_unreadable, path, reason}}}
          end

        {:ok, _other} ->
          {:halt, {:error, {:git_object_alternates_forbidden, path}}}

        {:error, reason} ->
          {:halt, {:error, {:git_object_alternates_unreadable, path, reason}}}
      end
    end)
  end

  defp capture_storage_identities(paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, identities} ->
      case storage_identity(path) do
        {:ok, identity} -> {:cont, {:ok, Map.put(identities, path, identity)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_storage_guard(%{authorized_root: root, identities: identities}) do
    with {:ok, canonical_root} <- SafePath.resolve_real(root),
         true <- canonical_root == root do
      Enum.reduce_while(identities, :ok, fn {path, expected}, :ok ->
        case storage_identity(path) do
          {:ok, ^expected} -> {:cont, :ok}
          _other -> {:halt, {:error, {:git_storage_identity_changed, path}}}
        end
      end)
    else
      _other -> {:error, {:git_storage_identity_changed, root}}
    end
  end

  defp storage_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.inode, stat.mode, stat.size, stat.mtime, stat.ctime}}

      _other ->
        {:error, {:invalid_git_storage_directory, path}}
    end
  end

  # Local/worktree helper config is audited fail-closed. The only intentional
  # exception is `core.hooksPath=/dev/null` (exact value), which disables hooks
  # rather than redirecting them. Every other matched helper key/value, any
  # hooksPath other than exact `/dev/null`, duplicate hooksPath rows, and
  # malformed config output are rejected. Audit uses argv + `--no-includes`
  # and Git's NUL-delimited output so values are compared byte-for-byte.
  defp reject_configured_helpers(path) do
    with :ok <- audit_config_scope(path, "--local"),
         {:ok, worktree_config?} <- worktree_config_enabled?(path) do
      if worktree_config?, do: audit_config_scope(path, "--worktree"), else: :ok
    end
  end

  defp audit_config_scope(path, scope) do
    args = [
      "config",
      scope,
      "--no-includes",
      "--null",
      "--get-regexp",
      @unsafe_config_pattern
    ]

    case execute_without_audit(path, args) do
      {:ok, %{exit_code: 1}} ->
        :ok

      {:ok, %{exit_code: 0, stdout: output}} ->
        evaluate_unsafe_config_matches(output)

      {:ok, result} ->
        {:error, {:git_config_audit_failed, result.exit_code, result.stdout}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evaluate_unsafe_config_matches(output) when is_binary(output) do
    with {:ok, entries} <- parse_config_regexp_output(output) do
      classify_unsafe_config_entries(entries)
    end
  end

  defp evaluate_unsafe_config_matches(_output),
    do: {:error, {:git_config_audit_failed, :invalid_config_output}}

  defp parse_config_regexp_output("") do
    {:error, {:git_config_audit_failed, :empty_match_output}}
  end

  defp parse_config_regexp_output(output) when is_binary(output) do
    if :binary.last(output) != 0 do
      {:error, {:git_config_audit_failed, :malformed_config_output}}
    else
      {terminator, records} =
        output
        |> :binary.split(<<0>>, [:global])
        |> List.pop_at(-1)

      parse_config_regexp_records(records, terminator)
    end
  end

  defp parse_config_regexp_output(_output),
    do: {:error, {:git_config_audit_failed, :invalid_config_output}}

  defp parse_config_regexp_records([], "") do
    {:error, {:git_config_audit_failed, :empty_match_output}}
  end

  defp parse_config_regexp_records(records, "") when is_list(records) do
    if Enum.any?(records, &(&1 == "")) do
      {:error, {:git_config_audit_failed, :malformed_config_output}}
    else
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
        case parse_config_regexp_record(record) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    end
  end

  defp parse_config_regexp_records(_records, _terminator) do
    {:error, {:git_config_audit_failed, :malformed_config_output}}
  end

  defp parse_config_regexp_record(record) when is_binary(record) do
    case :binary.split(record, "\n") do
      [key, value] when key != "" ->
        if String.valid?(key) do
          {:ok, {String.downcase(key), value}}
        else
          {:error, {:git_config_audit_failed, :malformed_config_record}}
        end

      _other ->
        {:error, {:git_config_audit_failed, :malformed_config_record}}
    end
  end

  defp parse_config_regexp_record(_record),
    do: {:error, {:git_config_audit_failed, :malformed_config_record}}

  defp classify_unsafe_config_entries(entries) when is_list(entries) do
    if entries == [] do
      {:error, {:git_config_audit_failed, :empty_match_output}}
    else
      do_classify_unsafe_config_entries(entries)
    end
  end

  defp classify_unsafe_config_entries(_entries),
    do: {:error, {:git_config_audit_failed, :invalid_config_entries}}

  defp do_classify_unsafe_config_entries(entries) do
    hooks_entries = Enum.filter(entries, fn {key, _value} -> key == "core.hookspath" end)
    other_entries = Enum.reject(entries, fn {key, _value} -> key == "core.hookspath" end)

    cond do
      other_entries != [] ->
        {:error, {:unsafe_git_configuration, format_config_entries(entries)}}

      length(hooks_entries) > 1 ->
        {:error, {:unsafe_git_configuration, format_config_entries(hooks_entries)}}

      hooks_entries == [{"core.hookspath", "/dev/null"}] ->
        :ok

      hooks_entries == [] ->
        {:error, {:git_config_audit_failed, :empty_match_output}}

      true ->
        {:error, {:unsafe_git_configuration, format_config_entries(hooks_entries)}}
    end
  end

  defp format_config_entries(entries) do
    entries
    |> Enum.map(fn {key, value} -> key <> " " <> value end)
    |> Enum.join("\n")
  end

  defp worktree_config_enabled?(path) do
    args = [
      "config",
      "--local",
      "--no-includes",
      "--type=bool",
      "--get",
      "extensions.worktreeConfig"
    ]

    case execute_without_audit(path, args) do
      {:ok, %{exit_code: 1}} ->
        {:ok, false}

      {:ok, %{exit_code: 0, stdout: output}} ->
        case String.trim(output) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          _other -> {:error, {:git_config_audit_failed, :invalid_worktree_config}}
        end

      {:ok, result} ->
        {:error, {:git_config_audit_failed, result.exit_code, result.stdout}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_primary_worktree(repository_root, repository_root),
    do: {:error, :primary_checkout_not_removable}

  defp reject_primary_worktree(_repository_root, _worktree_root), do: :ok

  defp remove_bound_worktree(repository_root, worktree_root, expected_identity) do
    with {:ok, repository_guard} <-
           validate_repository_storage(repository_root, storage_roots(repository_root)),
         {:ok, worktree_guard} <-
           validate_repository_storage(worktree_root, storage_roots(worktree_root)),
         :ok <- ensure_shared_common_dir(repository_root, worktree_root),
         :ok <- reject_configured_helpers(repository_root),
         :ok <- reject_configured_helpers(worktree_root),
         :ok <- verify_storage_guard(repository_guard),
         :ok <- verify_storage_guard(worktree_guard),
         :ok <-
           require_worktree_registration_identity(
             repository_root,
             worktree_root,
             expected_identity.worktree_registration
           ),
         :ok <-
           require_worktree_lstat_identity(worktree_root, expected_identity.lstat_identity) do
      execute_bound_worktree_remove(repository_root, worktree_root)
    end
  end

  defp validate_worktree_removal_identity(
         %{
           lstat_identity: lstat_identity,
           worktree_registration: worktree_registration
         } = identity
       )
       when map_size(identity) == 2 do
    with :ok <- validate_worktree_lstat_identity(lstat_identity),
         :ok <- validate_worktree_registration_identity(worktree_registration) do
      :ok
    end
  end

  defp validate_worktree_removal_identity(_identity),
    do: {:error, :invalid_git_worktree_identity}

  defp validate_worktree_lstat_identity(
         %{
           type: :directory,
           major_device: major_device,
           minor_device: minor_device,
           inode: inode
         } = identity
       )
       when map_size(identity) == 4 and is_integer(major_device) and major_device >= 0 and
              is_integer(minor_device) and minor_device >= 0 and is_integer(inode) and inode >= 0,
       do: :ok

  defp validate_worktree_lstat_identity(_identity),
    do: {:error, :invalid_git_worktree_identity}

  defp validate_worktree_registration_identity(%{path: path, branch: branch} = registration)
       when map_size(registration) in [2, 3] and is_binary(path) and path != "" and
              is_binary(branch) and branch != "" do
    if Map.has_key?(registration, :detached) do
      {:error, :invalid_git_worktree_identity}
    else
      validate_optional_registration_head(registration)
    end
  end

  defp validate_worktree_registration_identity(%{path: path, detached: true} = registration)
       when map_size(registration) in [2, 3] and is_binary(path) and path != "" do
    if Map.has_key?(registration, :branch) do
      {:error, :invalid_git_worktree_identity}
    else
      validate_optional_registration_head(registration)
    end
  end

  defp validate_worktree_registration_identity(_registration),
    do: {:error, :invalid_git_worktree_identity}

  defp validate_optional_registration_head(%{head: head})
       when is_binary(head) and head != "",
       do: :ok

  defp validate_optional_registration_head(registration) do
    if Map.has_key?(registration, :head),
      do: {:error, :invalid_git_worktree_identity},
      else: :ok
  end

  defp require_worktree_lstat_identity(worktree_root, expected_identity) do
    case File.lstat(worktree_root) do
      {:ok, %File.Stat{} = stat} ->
        current_identity =
          Map.take(Map.from_struct(stat), [:type, :major_device, :minor_device, :inode])

        if current_identity == expected_identity,
          do: :ok,
          else: {:error, :git_worktree_identity_mismatch}

      _missing_or_invalid ->
        {:error, :git_worktree_identity_mismatch}
    end
  end

  defp ensure_shared_common_dir(repository_root, worktree_root) do
    with {:ok, common_dir} <- query_repository_path(repository_root, "--git-common-dir"),
         {:ok, ^common_dir} <- query_repository_path(worktree_root, "--git-common-dir") do
      :ok
    else
      {:ok, _other_common_dir} -> {:error, :unrelated_git_worktree}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_worktree_registration_identity(
         repository_root,
         worktree_root,
         expected_registration
       ) do
    case execute_without_audit(repository_root, ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        with {:ok, registrations} <- parse_worktree_inventory(output),
             registration when is_map(registration) <-
               Enum.find(registrations, &(&1.path == worktree_root)),
             true <- registration_identity_matches?(registration, expected_registration) do
          :ok
        else
          nil -> {:error, :unregistered_git_worktree}
          false -> {:error, :git_worktree_registration_mismatch}
          {:error, reason} -> {:error, reason}
        end

      {:ok, result} ->
        {:error, {:git_worktree_list_failed, result.exit_code, result.stdout}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp registration_identity_matches?(current, expected) do
    current.path == expected.path and registration_state(current) == registration_state(expected)
  end

  defp registration_state(%{branch: branch}) when is_binary(branch), do: {:branch, branch}
  defp registration_state(%{detached: true}), do: :detached
  defp registration_state(_registration), do: :invalid

  defp worktree_inventory(repository_root) do
    case execute(repository_root, ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        parse_worktree_inventory(output)

      {:ok, %{exit_code: code, stdout: output}} ->
        {:error, {:git_worktree_list_failed, code, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_worktree_inventory(output) when is_binary(output) do
    output
    |> :binary.split(<<0, 0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case parse_worktree_record(record) do
        {:ok, registration} -> {:cont, {:ok, [registration | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registrations} -> {:ok, Enum.reverse(registrations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_worktree_record(record) do
    fields = :binary.split(record, <<0>>, [:global])

    with false <- Enum.any?(fields, &(&1 == "")),
         [path] <- field_values(fields, "worktree "),
         {:ok, canonical_path} <- canonical_comparison_path(path),
         [head] <- field_values(fields, "HEAD "),
         {:ok, state} <- parse_worktree_state(fields),
         :ok <- validate_worktree_fields(fields) do
      {:ok, Map.merge(%{path: canonical_path, head: head}, state)}
    else
      _ -> {:error, :invalid_git_worktree_inventory}
    end
  end

  defp parse_worktree_state(fields) do
    branches = field_values(fields, "branch refs/heads/")
    detached_count = Enum.count(fields, &(&1 == "detached"))

    case {branches, detached_count} do
      {[branch], 0} when branch != "" -> {:ok, %{branch: branch}}
      {[], 1} -> {:ok, %{detached: true}}
      _ -> {:error, :invalid_git_worktree_inventory}
    end
  end

  defp validate_worktree_fields(fields) do
    if Enum.all?(fields, &known_worktree_field?/1),
      do: :ok,
      else: {:error, :invalid_git_worktree_inventory}
  end

  defp known_worktree_field?(<<"worktree ", _::binary>>), do: true
  defp known_worktree_field?(<<"HEAD ", _::binary>>), do: true
  defp known_worktree_field?(<<"branch refs/heads/", _::binary>>), do: true
  defp known_worktree_field?("detached"), do: true
  defp known_worktree_field?("bare"), do: true
  defp known_worktree_field?("locked"), do: true
  defp known_worktree_field?(<<"locked ", _::binary>>), do: true
  defp known_worktree_field?("prunable"), do: true
  defp known_worktree_field?(<<"prunable ", _::binary>>), do: true
  defp known_worktree_field?(_field), do: false

  defp field_values(fields, prefix) do
    Enum.flat_map(fields, fn field ->
      if String.starts_with?(field, prefix) do
        [binary_part(field, byte_size(prefix), byte_size(field) - byte_size(prefix))]
      else
        []
      end
    end)
  end

  defp canonical_comparison_path(path) when is_binary(path) and path != "" do
    if String.valid?(path) and not String.contains?(path, <<0>>) do
      expanded = Path.expand(path)

      case SafePath.resolve_real(expanded) do
        {:ok, canonical} -> {:ok, canonical}
        {:error, _} -> canonical_missing_path(expanded)
      end
    else
      {:error, :invalid_git_worktree_path}
    end
  end

  defp canonical_comparison_path(_path), do: {:error, :invalid_git_worktree_path}

  defp canonical_missing_path(expanded) do
    ancestor = nearest_existing_ancestor(expanded)

    case SafePath.resolve_real(ancestor) do
      {:ok, canonical_ancestor} ->
        suffix = Path.relative_to(expanded, ancestor)

        {:ok,
         if(suffix == ".", do: canonical_ancestor, else: Path.join(canonical_ancestor, suffix))}

      {:error, _} ->
        {:error, :invalid_git_worktree_path}
    end
  end

  defp nearest_existing_ancestor(path) do
    if match?({:ok, _}, File.lstat(path)) do
      path
    else
      parent = Path.dirname(path)
      if parent == path, do: path, else: nearest_existing_ancestor(parent)
    end
  end

  # This is the sole destructive Git escape from the basic sandbox. The argv is
  # fixed here after both roots, shared storage, config, and identities are bound.
  defp execute_bound_worktree_remove(repository_root, worktree_root) do
    env = Map.put(@git_env, "GIT_CEILING_DIRECTORIES", repository_root)

    case Shell.execute_direct(
           "git",
           @git_prefix ++ ["worktree", "remove", "--force", worktree_root],
           cwd: repository_root,
           timeout: git_timeout(),
           sandbox: :none,
           env: env
         ) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, result} ->
        {:error, {:git_worktree_remove_failed, result.exit_code, result.stdout}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_without_audit(path, args) do
    env = Map.put(@git_env, "GIT_CEILING_DIRECTORIES", path)

    Shell.execute_direct("git", @git_prefix ++ args,
      cwd: path,
      timeout: git_timeout(),
      sandbox: git_sandbox(),
      env: env
    )
  end

  defp with_command_deadline(timeout_ms, fun)
       when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    requested_deadline = System.monotonic_time(:millisecond) + timeout_ms
    previous = Process.get(@git_deadline_key)

    deadline =
      case previous do
        existing when is_integer(existing) -> min(existing, requested_deadline)
        _other -> requested_deadline
      end

    Process.put(@git_deadline_key, deadline)

    try do
      fun.()
    after
      case previous do
        nil -> Process.delete(@git_deadline_key)
        existing -> Process.put(@git_deadline_key, existing)
      end
    end
  end

  defmodule Status do
    @moduledoc """
    Get repository status.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |

    ## Returns

    - `path` - Repository path
    - `branch` - Current branch name
    - `is_clean` - Whether the working tree is clean
    - `staged` - List of staged files
    - `modified` - List of modified (unstaged) files
    - `untracked` - List of untracked files
    - `ahead` - Commits ahead of upstream (if tracking)
    - `behind` - Commits behind upstream (if tracking)
    """

    use Jido.Action,
      name: "git_status",
      description: "Get the status of a Git repository",
      category: "git",
      tags: ["git", "status", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Git

    def taint_roles do
      %{path: {:control, requires: [:path_traversal]}}
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, branch_result} <- git_command(path, ["branch", "--show-current"]),
           {:ok, status_result} <- git_command(path, ["status", "--porcelain", "-b"]) do
        status = parse_status(status_result.stdout, branch_result.stdout)

        result = Map.put(status, :path, path)
        Actions.emit_completed(__MODULE__, %{path: path, is_clean: status.is_clean})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git status: #{reason}"}
      end
    end

    defp git_command(path, args) do
      case Git.execute(path, args) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr, stdout: stdout}} ->
          {:error, String.trim(if(stderr == "", do: stdout, else: stderr))}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp parse_status(porcelain_output, branch_output) do
      branch = String.trim(branch_output)
      lines = String.split(porcelain_output, "\n", trim: true)

      # Parse branch line for ahead/behind info
      {ahead, behind} = parse_tracking_info(Enum.at(lines, 0, ""))

      # Parse file status lines (skip first line which is branch info)
      file_lines = Enum.drop(lines, 1)

      {staged, modified, untracked} =
        Enum.reduce(file_lines, {[], [], []}, fn line, {s, m, u} ->
          case parse_status_line(line) do
            {:staged, file} -> {[file | s], m, u}
            {:modified, file} -> {s, [file | m], u}
            {:untracked, file} -> {s, m, [file | u]}
            :skip -> {s, m, u}
          end
        end)

      %{
        branch: branch,
        is_clean: Enum.empty?(staged) and Enum.empty?(modified) and Enum.empty?(untracked),
        staged: Enum.reverse(staged),
        modified: Enum.reverse(modified),
        untracked: Enum.reverse(untracked),
        ahead: ahead,
        behind: behind
      }
    end

    defp parse_tracking_info(line) do
      ahead =
        case Regex.run(~r/ahead (\d+)/, line) do
          [_, n] -> String.to_integer(n)
          nil -> 0
        end

      behind =
        case Regex.run(~r/behind (\d+)/, line) do
          [_, n] -> String.to_integer(n)
          nil -> 0
        end

      {ahead, behind}
    end

    defp parse_status_line(line) when byte_size(line) >= 3 do
      index = String.at(line, 0)
      worktree = String.at(line, 1)
      file = String.slice(line, 3..-1//1) |> String.trim()

      cond do
        worktree == "?" -> {:untracked, file}
        index in ["A", "M", "D", "R", "C"] and worktree == " " -> {:staged, file}
        worktree in ["M", "D"] -> {:modified, file}
        index in ["A", "M", "D", "R", "C"] -> {:staged, file}
        true -> :skip
      end
    end

    defp parse_status_line(_), do: :skip
  end

  defmodule Diff do
    @moduledoc """
    Show changes between commits, commit and working tree, etc.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `staged` | boolean | no | Show staged changes (default: false) |
    | `ref` | string | no | Compare against specific ref |
    | `file` | string | no | Show diff for specific file |
    | `stat_only` | boolean | no | Show diffstat only (default: false) |

    ## Returns

    - `path` - Repository path
    - `diff` - The diff output
    - `files_changed` - Number of files changed (if stat_only)
    - `insertions` - Lines added (if stat_only)
    - `deletions` - Lines removed (if stat_only)
    """

    use Jido.Action,
      name: "git_diff",
      description: "Show changes in a Git repository",
      category: "git",
      tags: ["git", "diff", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ],
        staged: [
          type: :boolean,
          default: false,
          doc: "Show staged (cached) changes"
        ],
        ref: [
          type: :string,
          doc: "Compare against specific ref (commit, branch, tag)"
        ],
        file: [
          type: :string,
          doc: "Show diff for specific file only"
        ],
        stat_only: [
          type: :boolean,
          default: false,
          doc: "Show diffstat summary only"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Git

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        ref: {:control, requires: [:command_injection]},
        file: {:control, requires: [:path_traversal]},
        staged: :control,
        stat_only: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      case build_diff_args(params) do
        {:ok, args} ->
          run_diff(path, params, args)

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git diff: #{inspect(reason)}"}
      end
    end

    defp run_diff(path, params, args) do
      case git_command(path, ["diff" | args]) do
        {:ok, result} ->
          output = %{
            path: path,
            diff: result.stdout
          }

          output =
            if params[:stat_only] do
              Map.merge(output, parse_stat(result.stdout))
            else
              output
            end

          Actions.emit_completed(__MODULE__, %{path: path})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git diff: #{reason}"}
      end
    end

    defp build_diff_args(params) do
      with :ok <- validate_optional_ref(params[:ref]),
           :ok <- validate_optional_path(params[:file]) do
        args = ["--no-ext-diff", "--no-textconv"]
        args = if params[:staged], do: args ++ ["--cached"], else: args
        args = if params[:stat_only], do: args ++ ["--stat"], else: args
        args = if params[:ref], do: args ++ [params[:ref]], else: args
        {:ok, args ++ ["--"] ++ List.wrap(params[:file])}
      end
    end

    defp validate_optional_ref(nil), do: :ok
    defp validate_optional_ref(ref), do: Git.validate_ref(ref)
    defp validate_optional_path(nil), do: :ok
    defp validate_optional_path(path), do: Git.validate_repo_path(path)

    defp git_command(path, args) do
      case Git.execute(path, args) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr, stdout: stdout}} ->
          {:error, String.trim(if(stderr == "", do: stdout, else: stderr))}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp parse_stat(output) do
      # Parse the summary line like "3 files changed, 10 insertions(+), 5 deletions(-)"
      case Regex.run(
             ~r/(\d+) files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?/,
             output
           ) do
        [_, files, insertions, deletions] ->
          %{
            files_changed: String.to_integer(files),
            insertions: parse_int_or_zero(insertions),
            deletions: parse_int_or_zero(deletions)
          }

        [_, files, insertions] ->
          %{
            files_changed: String.to_integer(files),
            insertions: parse_int_or_zero(insertions),
            deletions: 0
          }

        [_, files] ->
          %{
            files_changed: String.to_integer(files),
            insertions: 0,
            deletions: 0
          }

        nil ->
          %{files_changed: 0, insertions: 0, deletions: 0}
      end
    end

    defp parse_int_or_zero(nil), do: 0
    defp parse_int_or_zero(""), do: 0
    defp parse_int_or_zero(s), do: String.to_integer(s)
  end

  defmodule Commit do
    @moduledoc """
    Create a new commit.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `message` | string | yes | Commit message |
    | `files` | list | no | Files to stage before commit |
    | `all` | boolean | no | Stage all modified files (default: false) |
    | `allow_empty` | boolean | no | Allow empty commits (default: false) |
    | `expected_head_commit` | string | no | When set, require HEAD match before mutate |
    | `expected_tree_oid` | string | no | When set, require exact committable tree before mutate and resulting commit tree after |

    Ordinary callers omit the expected-* bindings. Pipeline owners that need an
    exact content-bound commit pass them; missing optional bindings preserve the
    generic commit behavior.

    ## Returns

    - `path` - Repository path
    - `commit_hash` - The new commit hash
    - `message` - Commit message
    - `files_committed` - Number of files in commit
    """

    use Jido.Action,
      name: "git_commit",
      description: "Create a new Git commit",
      category: "git",
      tags: ["git", "commit", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ],
        message: [
          type: :string,
          required: true,
          doc: "Commit message"
        ],
        files: [
          type: {:list, :string},
          doc: "Files to stage before commit"
        ],
        all: [
          type: :boolean,
          default: false,
          doc: "Stage all modified and deleted files"
        ],
        allow_empty: [
          type: :boolean,
          default: false,
          doc: "Allow creating empty commits"
        ],
        expected_head_commit: [
          type: :string,
          required: false,
          doc: "Optional exact HEAD binding enforced at the mutating boundary"
        ],
        expected_tree_oid: [
          type: :string,
          required: false,
          doc: "Optional exact committable-tree binding enforced at the mutating boundary"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Git
    alias Arbor.Actions.Mix, as: MixAction

    @git_oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        message: {:control, requires: [:command_injection]},
        files: {:control, requires: [:path_traversal]},
        all: :control,
        allow_empty: :control,
        expected_head_commit: :control,
        expected_tree_oid: :control
      }
    end

    # Mutates repository state (commit / stage). Static class is the max effect.
    def effect_class, do: :local_write

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, message: message} = params, _context) do
      Actions.emit_started(__MODULE__, %{path: path, message: message})

      # Stage files if specified
      with {:ok, message} <- normalize_message(message),
           :ok <- verify_optional_pre_commit_bindings(path, params),
           :ok <- maybe_stage_files(path, params),
           {:ok, commit_result} <- create_commit(path, message, params),
           {:ok, hash} <- get_commit_hash(path),
           :ok <- verify_optional_post_commit_tree(path, hash, params) do
        result = %{
          path: path,
          commit_hash: hash,
          message: message,
          output: commit_result.stdout
        }

        Actions.emit_completed(__MODULE__, %{path: path, commit_hash: hash})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to create commit: #{reason}"}
      end
    end

    defp verify_optional_pre_commit_bindings(path, params) do
      with :ok <- verify_optional_head(path, optional_binding(params, :expected_head_commit)),
           :ok <- verify_optional_tree(path, optional_binding(params, :expected_tree_oid)) do
        :ok
      end
    end

    # :absent — key omitted / nil (ordinary callers; skip check)
    # {:ok, oid} — well-formed binding
    # {:error, reason} — present but empty/malformed (fail closed before mutate)
    defp verify_optional_head(_path, :absent), do: :ok

    defp verify_optional_head(path, {:ok, expected}) do
      case get_commit_hash(path) do
        {:ok, ^expected} -> :ok
        {:ok, actual} -> {:error, "head mismatch: expected=#{expected} actual=#{actual}"}
        {:error, reason} -> {:error, reason}
      end
    end

    defp verify_optional_head(_path, {:error, reason}),
      do: {:error, "expected_head_commit is #{reason}"}

    defp verify_optional_tree(_path, :absent), do: :ok

    defp verify_optional_tree(path, {:ok, expected}) do
      case MixAction.committable_tree_binding(path) do
        {:ok, %{tree_oid: ^expected}} ->
          :ok

        {:ok, %{tree_oid: actual}} ->
          {:error, "tree mismatch: expected=#{expected} actual=#{actual}"}

        {:error, reason} ->
          {:error, "tree binding failed: #{inspect(reason)}"}
      end
    end

    defp verify_optional_tree(_path, {:error, reason}),
      do: {:error, "expected_tree_oid is #{reason}"}

    # Post-commit: compare the new commit object's tree to the expected binding.
    defp verify_optional_post_commit_tree(path, hash, params)
         when is_binary(path) and is_binary(hash) do
      case optional_binding(params, :expected_tree_oid) do
        :absent ->
          :ok

        {:ok, expected} ->
          case MixAction.commit_tree_oid(path, hash) do
            {:ok, ^expected} ->
              :ok

            {:ok, actual} ->
              {:error, "resulting tree mismatch: expected=#{expected} actual=#{actual}"}

            {:error, reason} ->
              {:error, "resulting tree lookup failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "expected_tree_oid is #{reason}"}
      end
    end

    defp optional_binding(params, key) when is_atom(key) do
      raw =
        cond do
          Map.has_key?(params, key) -> Map.get(params, key)
          Map.has_key?(params, Atom.to_string(key)) -> Map.get(params, Atom.to_string(key))
          true -> :__missing__
        end

      case raw do
        :__missing__ ->
          :absent

        nil ->
          :absent

        value when is_binary(value) and value == "" ->
          {:error, "invalid"}

        value when is_binary(value) ->
          if Regex.match?(@git_oid_re, value), do: {:ok, value}, else: {:error, "invalid"}

        _ ->
          {:error, "invalid"}
      end
    end

    defp normalize_message(message) when is_binary(message) do
      cond do
        not String.valid?(message) -> {:error, "commit message must be valid UTF-8"}
        String.contains?(message, <<0>>) -> {:error, "commit message contains NUL"}
        String.trim(message) == "" -> {:error, "commit message is required"}
        true -> {:ok, message}
      end
    end

    defp normalize_message(nil), do: {:error, "commit message is required"}
    defp normalize_message(_message), do: {:error, "commit message must be a string"}

    defp maybe_stage_files(path, %{files: files}) when is_list(files) and files != [] do
      with :ok <- validate_paths(files) do
        case git_command(path, ["add", "--" | files]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp maybe_stage_files(path, %{all: all}) when all in [true, "true", "1", 1] do
      case git_command(path, ["add", "-A", "--"]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_stage_files(_path, _params), do: :ok

    defp validate_paths(paths) do
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case Git.validate_repo_path(path) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp create_commit(path, message, params) do
      args = ["commit", "--no-verify", "--no-gpg-sign", "--cleanup=verbatim"]
      args = if enabled?(params[:allow_empty]), do: args ++ ["--allow-empty"], else: args
      args = args ++ ["-m", message, "--"]
      git_command(path, args)
    end

    defp enabled?(value), do: value in [true, "true", "1", 1]

    defp get_commit_hash(path) do
      case git_command(path, ["rev-parse", "HEAD"]) do
        {:ok, result} -> {:ok, String.trim(result.stdout)}
        error -> error
      end
    end

    defp git_command(path, args) do
      case Git.execute(path, args) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr, stdout: stdout}} ->
          error = if stderr != "", do: stderr, else: stdout
          {:error, String.trim(error)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defmodule Log do
    @moduledoc """
    Show commit history.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `limit` | integer | no | Maximum number of commits (default: 10) |
    | `ref` | string | no | Starting ref (branch, tag, commit) |
    | `oneline` | boolean | no | One line per commit (default: false) |
    | `file` | string | no | Show history for specific file |

    ## Returns

    - `path` - Repository path
    - `commits` - List of commit objects with hash, author, date, message
    - `count` - Number of commits returned
    """

    use Jido.Action,
      name: "git_log",
      description: "Show Git commit history",
      category: "git",
      tags: ["git", "log", "history", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ],
        limit: [
          type: :non_neg_integer,
          default: 10,
          doc: "Maximum number of commits to show"
        ],
        ref: [
          type: :string,
          doc: "Starting ref (branch, tag, commit)"
        ],
        oneline: [
          type: :boolean,
          default: false,
          doc: "Show one line per commit"
        ],
        file: [
          type: :string,
          doc: "Show history for specific file"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Git

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        ref: {:control, requires: [:command_injection]},
        file: {:control, requires: [:path_traversal]},
        limit: :data,
        oneline: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      case build_log_args(params) do
        {:ok, args} -> run_log(path, params, args)
        {:error, reason} -> {:error, "Failed to get git log: #{inspect(reason)}"}
      end
    end

    defp run_log(path, params, args) do
      case git_command(path, ["log" | args]) do
        {:ok, result} ->
          commits =
            if params[:oneline] do
              parse_oneline_log(result.stdout)
            else
              parse_log(result.stdout)
            end

          output = %{
            path: path,
            commits: commits,
            count: length(commits)
          }

          Actions.emit_completed(__MODULE__, %{path: path, count: length(commits)})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git log: #{reason}"}
      end
    end

    defp build_log_args(params) do
      with :ok <- validate_limit(params[:limit]),
           :ok <- validate_optional_ref(params[:ref]),
           :ok <- validate_optional_path(params[:file]) do
        args = ["--no-ext-diff", "--no-textconv", "-n", to_string(params[:limit] || 10)]

        args =
          if params[:oneline] do
            ["--oneline" | args]
          else
            ["--format=%H%n%an%n%ae%n%aI%n%s%n%b%n---COMMIT_END---" | args]
          end

        args = if params[:ref], do: args ++ [params[:ref]], else: args
        {:ok, args ++ ["--"] ++ List.wrap(params[:file])}
      end
    end

    defp validate_optional_ref(nil), do: :ok
    defp validate_optional_ref(ref), do: Git.validate_ref(ref)
    defp validate_optional_path(nil), do: :ok
    defp validate_optional_path(path), do: Git.validate_repo_path(path)

    defp validate_limit(nil), do: :ok
    defp validate_limit(limit) when is_integer(limit) and limit in 0..1000, do: :ok
    defp validate_limit(limit), do: {:error, {:invalid_git_log_limit, limit}}

    defp git_command(path, args) do
      case Git.execute(path, args) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr}} when stderr != "" ->
          {:error, String.trim(stderr)}

        {:ok, result} ->
          # Empty log is okay
          {:ok, result}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp parse_oneline_log(output) do
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, " ", parts: 2) do
          [hash, message] -> %{hash: hash, message: message}
          [hash] -> %{hash: hash, message: ""}
        end
      end)
    end

    defp parse_log(output) do
      output
      |> String.split("---COMMIT_END---", trim: true)
      |> Enum.map(&parse_commit_block/1)
      |> Enum.reject(&is_nil/1)
    end

    defp parse_commit_block(block) do
      lines = String.split(block, "\n", trim: true)

      case lines do
        [hash, author, email, date, subject | body_lines] ->
          %{
            hash: hash,
            author: author,
            email: email,
            date: date,
            subject: subject,
            body: Enum.join(body_lines, "\n") |> String.trim()
          }

        _ ->
          nil
      end
    end
  end

  defmodule Branch do
    @moduledoc """
    Create, switch, or list branches.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `mode` | atom | yes | `:create`, `:switch`, or `:list` |
    | `name` | string | conditional | Branch name (required for `:create` / `:switch`) |
    | `from` | string | no | Base ref for `:create` (default: current HEAD) |

    ## Returns

    - `path` — repository path
    - `mode` — operation performed
    - `branch` — branch name (for `:create` / `:switch`)
    - `branches` — list of branch names (for `:list`)
    - `current` — current branch name (for `:list`)
    """

    use Jido.Action,
      name: "git_branch",
      description: "Create, switch, or list Git branches",
      category: "git",
      tags: ["git", "branch", "vcs"],
      schema: [
        path: [type: :string, required: true, doc: "Path to the Git repository"],
        mode: [
          type: {:in, [:create, :switch, :list]},
          required: true,
          doc: "Operation: :create, :switch, or :list"
        ],
        name: [type: :string, doc: "Branch name (for :create / :switch)"],
        from: [type: :string, doc: "Base ref for :create (default: HEAD)"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Git

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        mode: :control,
        name: {:control, requires: [:command_injection]},
        from: {:control, requires: [:command_injection]}
      }
    end

    # create/switch mutate repo state; list is read-only. Static class is max effect.
    def effect_class, do: :local_write

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, mode: :list} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, branches_result} <- git_command(path, ["branch", "--list"]),
           {:ok, current_result} <- git_command(path, ["branch", "--show-current"]) do
        branches =
          branches_result.stdout
          |> String.split("\n", trim: true)
          |> Enum.map(&(String.trim_leading(&1, "* ") |> String.trim()))
          |> Enum.reject(&(&1 == ""))

        result = %{
          path: path,
          mode: :list,
          branches: branches,
          current: String.trim(current_result.stdout)
        }

        Actions.emit_completed(__MODULE__, %{path: path, count: length(branches)})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to list branches: #{reason}"}
      end
    end

    def run(%{path: path, mode: :create, name: name} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      with :ok <- Git.validate_branch_name(name),
           :ok <- validate_optional_ref(params[:from]),
           args = ["switch", "-c", name, "--"] ++ List.wrap(params[:from]),
           {:ok, _result} <- git_command(path, args) do
        result = %{path: path, mode: :create, branch: name}
        Actions.emit_completed(__MODULE__, %{path: path, branch: name})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to create branch '#{name}': #{inspect(reason)}"}
      end
    end

    def run(%{path: path, mode: :switch, name: name} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      with :ok <- Git.validate_branch_name(name),
           {:ok, _result} <- git_command(path, ["switch", "--", name]) do
        result = %{path: path, mode: :switch, branch: name}
        Actions.emit_completed(__MODULE__, %{path: path, branch: name})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to switch to branch '#{name}': #{inspect(reason)}"}
      end
    end

    def run(%{mode: mode}, _context) when mode in [:create, :switch] do
      {:error, "Branch mode :#{mode} requires a 'name' parameter"}
    end

    defp validate_optional_ref(nil), do: :ok
    defp validate_optional_ref(ref), do: Git.validate_ref(ref)

    defp git_command(path, args) do
      case Git.execute(path, args) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr, stdout: stdout}} ->
          error = if stderr != "", do: stderr, else: stdout
          {:error, String.trim(error)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defmodule PR do
    @moduledoc """
    Open a draft pull request or merge request through the configured SCM.

    This is intentionally one platform-agnostic action. The caller supplies the
    review content and branch names; provider, endpoint, and token are resolved
    from action config or the selected git remote.
    """

    use Jido.Action,
      name: "git_pr",
      description: "Open a draft pull request or merge request through the configured SCM",
      category: "git",
      tags: ["git", "pr", "mr", "vcs"],
      schema: [
        path: [type: :string, required: true, doc: "Path to the Git repository"],
        head: [type: :string, doc: "Source branch name"],
        branch: [type: :string, doc: "Source branch name alias"],
        base: [type: :string, default: "main", doc: "Target branch name"],
        title: [type: :string, required: true, doc: "PR/MR title"],
        body: [type: :string, doc: "PR/MR body"],
        draft: [type: :boolean, default: true, doc: "Open as draft"],
        owner: [type: :string, doc: "Repository owner/group override"],
        repo: [type: :string, doc: "Repository name override"],
        remote: [type: :string, default: "origin", doc: "Git remote to derive owner/repo from"],
        provider: [type: {:in, [:github, :gitlab, :gitea]}, doc: "SCM provider override"],
        scm_base_url: [type: :string, doc: "SCM API base URL override"],
        project_id: [type: :string, doc: "GitLab project id/path override"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Config
    alias Arbor.Actions.Git
    alias Arbor.Common.{EgressClassifier, SensitiveData}

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        head: {:control, requires: [:command_injection]},
        branch: {:control, requires: [:command_injection]},
        base: {:control, requires: [:command_injection]},
        title: {:control, requires: [:command_injection]},
        body: {:control, requires: [:command_injection]},
        draft: :control,
        owner: {:control, requires: [:command_injection]},
        repo: {:control, requires: [:command_injection]},
        remote: {:control, requires: [:command_injection]},
        provider: :control,
        scm_base_url: {:control, requires: [:ssrf]},
        project_id: {:control, requires: [:command_injection]}
      }
    end

    def effect_class, do: :network_egress

    def egress_tier(params, context) do
      case resolved_base_url(params, context) do
        {:ok, base_url} ->
          case EgressClassifier.locality(base_url) do
            :on_host -> :on_host
            :on_premises -> :on_premises
            :public -> :external_peer
          end

        {:error, _reason} ->
          :external_provider
      end
    end

    def egress_destination(params, context) do
      with {:ok, base_url} <- resolved_base_url(params, context),
           %URI{host: host} when is_binary(host) <- URI.parse(base_url) do
        host
      else
        _ -> nil
      end
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, title: title} = params, context) do
      Actions.emit_started(__MODULE__, %{
        path: path,
        title: title,
        remote: Config.get(params, :remote, "origin")
      })

      remote = Config.get(params, :remote, "origin")

      with :ok <- validate_remote_name(remote),
           remote_result = remote_info(params),
           remote_hint = remote_hint(remote_result),
           {:ok, provider} <- Config.scm_provider(params, context, remote_hint),
           {:ok, base_url} <- Config.scm_base_url(provider, params, context, remote_hint),
           {:ok, token} <- Config.scm_token(provider, params, context),
           {:ok, head} <- resolve_head(path, params),
           {:ok, {owner, repo}} <- resolve_owner_repo(params, remote_result),
           {:ok, request} <-
             build_request(provider, base_url, owner, repo, head, params),
           {:ok, response} <- post_request(request, provider, token, context),
           {:ok, result} <- normalize_response(provider, response, params) do
        completed = Map.merge(result, %{provider: provider, owner: owner, repo: repo, head: head})
        Actions.emit_completed(__MODULE__, Map.drop(completed, [:body]))
        {:ok, completed}
      else
        {:error, reason} ->
          safe_reason = redact(reason, nil)
          Actions.emit_failed(__MODULE__, safe_reason)
          {:error, safe_reason}
      end
    end

    def run(_params, _context), do: {:error, "path and title are required"}

    defp resolved_base_url(params, context) do
      remote_result = remote_info(params)
      remote_hint = remote_hint(remote_result)

      with {:ok, provider} <- Config.scm_provider(params, context, remote_hint) do
        Config.scm_base_url(provider, params, context, remote_hint)
      end
    end

    defp remote_hint({:ok, remote}), do: remote
    defp remote_hint({:error, _reason}), do: nil

    defp remote_info(params) do
      path = Config.get(params, :path)
      remote = Config.get(params, :remote, "origin")

      with :ok <- validate_remote_name(remote) do
        case Git.execute(path, ["remote", "get-url", "--", remote]) do
          {:ok, %{exit_code: 0, stdout: output}} ->
            parse_remote_url(String.trim(output), remote)

          {:ok, result} ->
            output = if result.stderr == "", do: result.stdout, else: result.stderr
            {:error, "failed to read git remote #{inspect(remote)}: #{String.trim(output)}"}

          {:error, reason} ->
            {:error, "failed to read git remote #{inspect(remote)}: #{inspect(reason)}"}
        end
      end
    end

    defp validate_remote_name(remote) when is_binary(remote) do
      if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, remote) and
           byte_size(remote) <= 255 and not String.contains?(remote, ["..", "//"]) do
        :ok
      else
        {:error, "invalid git remote name: #{inspect(remote)}"}
      end
    end

    defp validate_remote_name(remote), do: {:error, "invalid git remote name: #{inspect(remote)}"}

    defp parse_remote_url(url, remote) do
      parsed =
        if String.contains?(url, "://") do
          parse_uri_remote(url)
        else
          parse_scp_remote(url)
        end

      case parsed do
        {:ok, info} -> {:ok, Map.merge(info, %{remote: remote, url: url})}
        {:error, reason} -> {:error, reason}
      end
    end

    defp parse_uri_remote(url) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, path: path, port: port}
        when is_binary(scheme) and is_binary(host) and is_binary(path) ->
          with {:ok, owner, repo} <- owner_repo_from_path(path) do
            {:ok,
             %{scheme: scheme, host: String.downcase(host), port: port, owner: owner, repo: repo}}
          end

        _ ->
          {:error, "unsupported git remote URL: #{url}"}
      end
    end

    defp parse_scp_remote(url) do
      case Regex.run(~r/^(?:[^@]+@)?([^:\/]+):(.+)$/, url) do
        [_, host, path] ->
          with {:ok, owner, repo} <- owner_repo_from_path(path) do
            {:ok,
             %{scheme: nil, host: String.downcase(host), port: nil, owner: owner, repo: repo}}
          end

        _ ->
          {:error, "unsupported git remote URL: #{url}"}
      end
    end

    defp owner_repo_from_path(path) do
      parts =
        path
        |> String.trim_leading("/")
        |> String.trim_trailing(".git")
        |> String.split("/", trim: true)

      case parts do
        [_repo] ->
          {:error, "git remote URL does not include an owner/group"}

        parts when length(parts) >= 2 ->
          {owner_parts, [repo]} = Enum.split(parts, -1)
          {:ok, Enum.join(owner_parts, "/"), repo}

        _ ->
          {:error, "git remote URL does not include a repository path"}
      end
    end

    defp resolve_owner_repo(params, remote_result) do
      owner = Config.get(params, :owner)
      repo = Config.get(params, :repo)

      cond do
        is_binary(owner) and owner != "" and is_binary(repo) and repo != "" ->
          {:ok, {owner, repo}}

        match?({:ok, _}, remote_result) ->
          {:ok, remote} = remote_result
          {:ok, {remote.owner, remote.repo}}

        true ->
          remote_result
      end
    end

    defp resolve_head(_path, params) do
      case Config.get(params, :head) || Config.get(params, :branch) do
        value when is_binary(value) and value != "" ->
          case Git.validate_branch_name(value) do
            :ok -> {:ok, value}
            {:error, reason} -> {:error, inspect(reason)}
          end

        _ ->
          current_branch(Config.get(params, :path))
      end
    end

    defp current_branch(path) do
      case Git.execute(path, ["branch", "--show-current"]) do
        {:ok, %{exit_code: 0, stdout: output}} ->
          case String.trim(output) do
            "" -> {:error, "head/branch is required when the repo is detached"}
            branch -> {:ok, branch}
          end

        {:ok, result} ->
          output = if result.stderr == "", do: result.stdout, else: result.stderr
          {:error, "failed to resolve current git branch: #{String.trim(output)}"}

        {:error, reason} ->
          {:error, "failed to resolve current git branch: #{inspect(reason)}"}
      end
    end

    defp build_request(:github, base_url, owner, repo, head, params) do
      body = %{
        "head" => head,
        "base" => base_branch(params),
        "title" => Config.get(params, :title),
        "body" => Config.get(params, :body, ""),
        "draft" => draft?(params)
      }

      {:ok,
       %{url: "#{base_url}/repos/#{path_segment(owner)}/#{path_segment(repo)}/pulls", body: body}}
    end

    defp build_request(:gitea, base_url, owner, repo, head, params) do
      body = %{
        "head" => head,
        "base" => base_branch(params),
        "title" => Config.get(params, :title),
        "body" => Config.get(params, :body, ""),
        "draft" => draft?(params)
      }

      {:ok,
       %{
         url: "#{base_url}/api/v1/repos/#{path_segment(owner)}/#{path_segment(repo)}/pulls",
         body: body
       }}
    end

    defp build_request(:gitlab, base_url, owner, repo, head, params) do
      project_id = Config.get(params, :project_id) || "#{owner}/#{repo}"
      title = draft_title(Config.get(params, :title), draft?(params))

      body = %{
        "source_branch" => head,
        "target_branch" => base_branch(params),
        "title" => title,
        "description" => Config.get(params, :body, "")
      }

      {:ok,
       %{
         url: "#{base_url}/api/v4/projects/#{URI.encode_www_form(project_id)}/merge_requests",
         body: body
       }}
    end

    defp post_request(%{url: url, body: body}, provider, token, context) do
      opts = [
        json: body,
        headers: headers(provider, token),
        receive_timeout: 60_000,
        retry: false
      ]

      case http_post(url, opts, context) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: status, body: response_body}} ->
          safe_body =
            response_body
            |> inspect()
            |> SensitiveData.redact()
            |> redact(token)

          {:error, "SCM PR request failed: HTTP #{status}: #{safe_body}"}

        {:error, reason} ->
          {:error, "SCM PR request failed: #{redact(inspect(reason), token)}"}
      end
    end

    defp http_post(url, opts, context) do
      case Config.get(context, :http_request) do
        request when is_function(request, 3) -> request.(:post, url, opts)
        request when is_function(request, 2) -> request.(url, opts)
        _ -> Req.post(url, opts)
      end
    end

    defp normalize_response(provider, body, params) when is_map(body) do
      number =
        body["number"] || body[:number] || body["iid"] || body[:iid] || body["id"] || body[:id]

      url =
        body["html_url"] || body[:html_url] || body["web_url"] || body[:web_url] || body["url"] ||
          body[:url]

      if is_binary(url) and url != "" do
        {:ok,
         %{
           number: number,
           url: url,
           title: Config.get(params, :title),
           draft?: draft?(params),
           kind: if(provider == :gitlab, do: "merge_request", else: "pull_request")
         }}
      else
        {:error, "SCM PR response did not include a URL"}
      end
    end

    defp normalize_response(_provider, body, _params) do
      {:error, "SCM PR response was not a JSON object: #{inspect(body)}"}
    end

    defp headers(:github, token) do
      [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"content-type", "application/json"}
      ]
    end

    defp headers(:gitlab, token) do
      [
        {"private-token", token},
        {"accept", "application/json"},
        {"content-type", "application/json"}
      ]
    end

    defp headers(:gitea, token) do
      [
        {"authorization", "token #{token}"},
        {"accept", "application/json"},
        {"content-type", "application/json"}
      ]
    end

    defp base_branch(params), do: Config.get(params, :base, "main")
    defp draft?(params), do: Config.get(params, :draft, true) != false

    defp draft_title(title, true) do
      if String.starts_with?(title, "Draft:"), do: title, else: "Draft: #{title}"
    end

    defp draft_title(title, false), do: title

    defp path_segment(value) do
      value
      |> to_string()
      |> String.split("/", trim: true)
      |> Enum.map_join("/", &URI.encode/1)
    end

    defp redact(text, secret) do
      text
      |> SensitiveData.redact()
      |> Config.redact_secret(secret)
    end
  end
end
