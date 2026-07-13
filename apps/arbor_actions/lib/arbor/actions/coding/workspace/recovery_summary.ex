defmodule Arbor.Actions.Coding.Workspace.RecoverySummary do
  @moduledoc """
  Build a bounded prompt for resuming work after conversation state is lost.

  The active workspace lease is the authority boundary. The prompt reports only
  bounded Git metadata and repository-relative status paths; it never includes
  raw diffs, environment data, credentials, capabilities, or workspace paths.
  """

  use Jido.Action,
    name: "coding_workspace_recovery_summary",
    description: "Build a bounded recovery prompt from an authorized coding workspace lease",
    category: "coding",
    tags: ["coding", "workspace", "worktree", "git", "lease", "recovery"],
    schema: [
      workspace_id: [
        type: :string,
        required: true,
        doc: "Opaque workspace lease id from acquire"
      ],
      task: [
        type: :string,
        required: true,
        doc: "Pending coding task"
      ],
      pending_prompt: [
        type: :string,
        required: true,
        doc: "Pending prompt to resume"
      ],
      validation_feedback_json: [
        type: :string,
        doc: "Optional latest validation feedback encoded as JSON"
      ],
      review_feedback_json: [
        type: :string,
        doc: "Optional latest review feedback encoded as JSON"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git

  @max_commits 20
  @max_commit_subject_bytes 160
  @max_status_entries 10
  @max_status_path_bytes 160
  @max_task_bytes 2_048
  @max_pending_prompt_bytes 4_096
  @max_feedback_bytes 2_048
  @max_shortstat_bytes 512
  @max_recovery_prompt_bytes 24_576
  @exact_oid ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def taint_roles do
    %{
      workspace_id: :control,
      task: {:control, requires: [:prompt_injection]},
      pending_prompt: {:control, requires: [:prompt_injection]},
      validation_feedback_json: {:control, requires: [:prompt_injection]},
      review_feedback_json: {:control, requires: [:prompt_injection]}
    }
  end

  def effect_class, do: :read

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(
        %{workspace_id: workspace_id, task: task, pending_prompt: pending_prompt} = params,
        context
      )
      when is_binary(workspace_id) and is_binary(task) and is_binary(pending_prompt) do
    Actions.emit_started(__MODULE__, %{workspace_id: workspace_id})

    with {:ok, lease} <- authorized_lease(workspace_id, context),
         {:ok, input} <- normalize_input(task, pending_prompt, params),
         {:ok, git_state} <- collect_git_state(lease),
         prompt <- build_prompt(git_state, input),
         :ok <- require_bounded_prompt(prompt) do
      Actions.emit_completed(__MODULE__, %{
        workspace_id: workspace_id,
        commit_count: length(git_state.commits)
      })

      {:ok, %{workspace_id: workspace_id, recovery_prompt: prompt}}
    else
      {:error, reason} ->
        Actions.emit_failed(__MODULE__, reason)
        {:error, reason}
    end
  end

  def run(_params, _context),
    do: {:error, "workspace_id, task, and pending_prompt are required"}

  defp authorized_lease(workspace_id, context) do
    WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context)
    })
  end

  defp normalize_input(task, pending_prompt, params) do
    with {:ok, task} <- bounded_input(task, @max_task_bytes, :invalid_task),
         {:ok, pending_prompt} <-
           bounded_input(pending_prompt, @max_pending_prompt_bytes, :invalid_pending_prompt),
         {:ok, validation_feedback} <-
           normalize_feedback(
             map_value(params, :validation_feedback_json),
             :invalid_validation_feedback_json
           ),
         {:ok, review_feedback} <-
           normalize_feedback(
             map_value(params, :review_feedback_json),
             :invalid_review_feedback_json
           ) do
      {:ok,
       %{
         task: task,
         pending_prompt: pending_prompt,
         validation_feedback: validation_feedback,
         review_feedback: review_feedback
       }}
    end
  end

  defp normalize_feedback(nil, _error), do: {:ok, nil}
  defp normalize_feedback("", _error), do: {:ok, nil}

  defp normalize_feedback(json, error) when is_binary(json) do
    with true <- String.valid?(json),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, canonical} <- Jason.encode(decoded) do
      {:ok, bounded_feedback_json(canonical)}
    else
      _other -> {:error, error}
    end
  end

  defp normalize_feedback(_json, error), do: {:error, error}

  defp bounded_input(value, max_bytes, error) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, bounded_text(sanitize_text(value), max_bytes)},
      else: {:error, error}
  end

  defp collect_git_state(lease) do
    repo_path = map_value(lease, :repo_path)
    worktree_path = map_value(lease, :worktree_path)
    branch = map_value(lease, :branch)
    base = map_value(lease, :base_commit)

    with :ok <- require_workspace_refs(branch, base),
         true <- is_binary(repo_path) and is_binary(worktree_path),
         {:ok, result} <-
           Git.with_storage_authority(repo_path, worktree_path, fn ->
             collect_authorized_git_state(worktree_path, branch, base)
           end) do
      {:ok, result}
    else
      false -> {:error, :invalid_workspace_lease}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_workspace_lease}
    end
  end

  defp require_workspace_refs(branch, base) do
    with :ok <- Git.validate_branch_name(branch),
         true <- is_binary(base) and Regex.match?(@exact_oid, base) do
      :ok
    else
      _other -> {:error, :invalid_workspace_ref_state}
    end
  end

  defp collect_authorized_git_state(path, expected_branch, base) do
    with {:ok, branch} <- current_branch(path),
         :ok <- require_equal(branch, expected_branch, :workspace_branch_mismatch),
         {:ok, head} <- exact_commit(path, "HEAD"),
         {:ok, resolved_base} <- exact_commit(path, base),
         :ok <- require_equal(resolved_base, base, :invalid_workspace_base),
         :ok <- require_base_ancestor(path, base, head),
         {:ok, commits} <- commits(path, base, head),
         {:ok, shortstat} <- diff_shortstat(path, base, head),
         {:ok, status} <- status_summary(path),
         {:ok, final_branch} <- current_branch(path),
         :ok <- require_equal(final_branch, branch, :workspace_ref_changed),
         {:ok, final_head} <- exact_commit(path, "HEAD"),
         :ok <- require_equal(final_head, head, :workspace_ref_changed) do
      {:ok,
       %{
         branch: branch,
         base: base,
         head: head,
         commits: commits,
         shortstat: shortstat,
         dirty: status.dirty,
         dirty_total: status.dirty_total,
         untracked: status.untracked,
         untracked_total: status.untracked_total
       }}
    end
  end

  defp current_branch(path) do
    git_stdout(path, ["symbolic-ref", "--quiet", "--short", "HEAD"], :invalid_branch_state)
  end

  defp exact_commit(path, ref) do
    with {:ok, oid} <-
           git_stdout(path, ["rev-parse", "--verify", "#{ref}^{commit}"], :invalid_ref_state),
         true <- Regex.match?(@exact_oid, oid) do
      {:ok, oid}
    else
      _other -> {:error, :invalid_ref_state}
    end
  end

  defp require_base_ancestor(path, base, head) do
    case git_result(path, ["merge-base", "--is-ancestor", base, head]) do
      {:ok, %{exit_code: 0}} -> :ok
      _other -> {:error, :base_not_ancestor_of_head}
    end
  end

  defp commits(path, base, head) do
    args = [
      "log",
      "--no-decorate",
      "--no-show-signature",
      "--max-count=#{@max_commits}",
      "--format=%H%x09%s",
      "#{base}..#{head}"
    ]

    with {:ok, output} <- git_stdout(path, args, :commit_log_failed) do
      commits =
        output
        |> String.split("\n", trim: true)
        |> Enum.take(@max_commits)
        |> Enum.map(&format_commit/1)

      {:ok, commits}
    end
  end

  defp format_commit(line) do
    case String.split(line, "\t", parts: 2) do
      [oid, subject] when byte_size(oid) in [40, 64] ->
        "#{oid} #{bounded_text(sanitize_line(subject), @max_commit_subject_bytes)}"

      _other ->
        "[invalid commit summary omitted]"
    end
  end

  defp diff_shortstat(path, base, head) do
    with {:ok, output} <-
           git_stdout(
             path,
             ["diff", "--no-ext-diff", "--shortstat", "#{base}..#{head}"],
             :diff_shortstat_failed
           ) do
      summary =
        case sanitize_line(output) do
          "" -> "no committed file changes"
          value -> bounded_text(value, @max_shortstat_bytes)
        end

      {:ok, summary}
    end
  end

  defp status_summary(path) do
    with {:ok, output} <-
           git_stdout(
             path,
             ["status", "--porcelain=v1", "--untracked-files=all"],
             :workspace_status_failed
           ) do
      {dirty, dirty_total, untracked, untracked_total} =
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce({[], 0, [], 0}, fn line,
                                          {dirty, dirty_total, untracked, untracked_total} ->
          entry = bounded_text(sanitize_line(line), @max_status_path_bytes + 3)

          if String.starts_with?(entry, "?? ") do
            {dirty, dirty_total, append_bounded(untracked, entry), untracked_total + 1}
          else
            {append_bounded(dirty, entry), dirty_total + 1, untracked, untracked_total}
          end
        end)

      {:ok,
       %{
         dirty: dirty,
         dirty_total: dirty_total,
         untracked: untracked,
         untracked_total: untracked_total
       }}
    end
  end

  defp append_bounded(entries, entry) when length(entries) < @max_status_entries,
    do: entries ++ [entry]

  defp append_bounded(entries, _entry), do: entries

  defp git_stdout(path, args, error) do
    case git_result(path, args) do
      {:ok, %{exit_code: 0, stdout: output}} when is_binary(output) ->
        {:ok, String.trim(output)}

      _other ->
        {:error, error}
    end
  end

  defp git_result(path, args) do
    case Git.execute(path, args) do
      {:ok, result} ->
        if result.timed_out or result.output_limit_exceeded,
          do: {:error, :bounded_git_command_failed},
          else: {:ok, result}

      {:error, _reason} ->
        {:error, :bounded_git_command_failed}
    end
  end

  defp build_prompt(git_state, input) do
    """
    RECOVERY CONTEXT

    Prior conversation was lost. Treat the current worktree state as authoritative.
    Steering history and the prior transcript are unavailable; do not claim to remember them.

    Git state
    - Branch: #{git_state.branch}
    - Base: #{git_state.base}
    - HEAD: #{git_state.head}
    - Diff shortstat: #{git_state.shortstat}

    Commits (base..HEAD, at most #{@max_commits})
    #{format_list(git_state.commits, "(none)")}

    Dirty tracked entries (showing at most #{@max_status_entries} of #{git_state.dirty_total}, repository-relative)
    #{format_list(git_state.dirty, "(none)")}

    Untracked entries (showing at most #{@max_status_entries} of #{git_state.untracked_total}, repository-relative)
    #{format_list(git_state.untracked, "(none)")}

    Pending task
    <task>
    #{input.task}
    </task>

    Pending prompt
    <pending_prompt>
    #{input.pending_prompt}
    </pending_prompt>

    Latest validation feedback
    <validation_feedback_json>
    #{input.validation_feedback || "(unavailable)"}
    </validation_feedback_json>

    Latest review feedback
    <review_feedback_json>
    #{input.review_feedback || "(unavailable)"}
    </review_feedback_json>
    """
    |> String.trim()
  end

  defp format_list([], empty), do: empty
  defp format_list(entries, _empty), do: Enum.map_join(entries, "\n", &"- #{&1}")

  defp require_bounded_prompt(prompt) when byte_size(prompt) <= @max_recovery_prompt_bytes,
    do: :ok

  defp require_bounded_prompt(_prompt), do: {:error, :recovery_prompt_too_large}

  defp require_equal(value, value, _error), do: :ok
  defp require_equal(_actual, _expected, error), do: {:error, error}

  defp sanitize_text(value) do
    String.replace(value, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
  end

  defp sanitize_line(value) do
    value
    |> sanitize_text()
    |> String.replace(["\r", "\n"], " ")
    |> String.trim()
  end

  defp bounded_text(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp bounded_text(value, max_bytes) do
    suffix = "...[truncated]"
    prefix_bytes = max(max_bytes - byte_size(suffix), 0)
    utf8_prefix(value, prefix_bytes) <> suffix
  end

  defp bounded_feedback_json(canonical) when byte_size(canonical) <= @max_feedback_bytes,
    do: canonical

  defp bounded_feedback_json(canonical) do
    envelope = %{
      "original_bytes" => byte_size(canonical),
      "preview" => "",
      "truncated" => true
    }

    fit_feedback_preview(canonical, envelope, min(byte_size(canonical), @max_feedback_bytes))
  end

  defp fit_feedback_preview(canonical, envelope, preview_bytes) do
    preview = utf8_prefix(canonical, preview_bytes)
    encoded = Jason.encode!(Map.put(envelope, "preview", preview))

    if byte_size(encoded) <= @max_feedback_bytes do
      encoded
    else
      overflow = byte_size(encoded) - @max_feedback_bytes
      next_bytes = max(preview_bytes - max(overflow, 1), 0)
      fit_feedback_preview(canonical, envelope, next_bytes)
    end
  end

  defp utf8_prefix(_value, 0), do: ""

  defp utf8_prefix(value, max_bytes) do
    size = min(byte_size(value), max_bytes)
    valid_prefix(value, size)
  end

  defp valid_prefix(_value, 0), do: ""

  defp valid_prefix(value, size) do
    prefix = binary_part(value, 0, size)
    if String.valid?(prefix), do: prefix, else: valid_prefix(value, size - 1)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
