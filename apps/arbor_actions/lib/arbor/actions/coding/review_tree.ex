defmodule Arbor.Actions.Coding.ReviewTree do
  @moduledoc """
  Schema-bounded commit-tree read/search for coding review snapshots.

  These actions resolve an opaque `review_snapshot_id` through
  `Arbor.Actions.Coding.WorkspaceLeaseRegistry`, derive the exact candidate or
  base commit from that snapshot, and read tracked tree content via argv-based
  Git plumbing. They never accept arbitrary refs/commits and never read the
  live worktree.

  | Action | Canonical URI |
  |--------|---------------|
  | `Read` | `arbor://action/coding/review_tree/read` |
  | `Search` | `arbor://action/coding/review_tree/search` |
  """

  @max_path_bytes 1024
  @max_content_bytes 262_144
  @max_query_bytes 256
  @max_search_limit 100
  @default_search_limit 20
  @max_match_line_bytes 1024
  @max_total_match_bytes 262_144

  @doc false
  def max_content_bytes, do: @max_content_bytes

  @doc false
  def max_query_bytes, do: @max_query_bytes

  @doc false
  def max_search_limit, do: @max_search_limit

  @doc false
  def default_search_limit, do: @default_search_limit

  @doc false
  def max_path_bytes, do: @max_path_bytes

  @doc false
  @spec validate_repo_relative_path(term()) :: {:ok, String.t()} | {:error, term()}
  def validate_repo_relative_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :invalid_path}

      not String.valid?(path) ->
        {:error, :invalid_utf8}

      String.contains?(path, <<0>>) ->
        {:error, :invalid_path}

      byte_size(path) > @max_path_bytes ->
        {:error, :path_too_long}

      Path.type(path) == :absolute or String.starts_with?(path, "/") or
          String.match?(path, ~r/^[A-Za-z]:[\\\/]/) ->
        {:error, :absolute_path}

      String.contains?(path, ["\\", ":"]) ->
        {:error, :invalid_path}

      Enum.any?(Path.split(path), &(&1 in ["..", ".git", ""])) ->
        {:error, :path_traversal}

      String.starts_with?(path, "./") ->
        validate_repo_relative_path(String.trim_leading(path, "./"))

      true ->
        {:ok, path}
    end
  end

  def validate_repo_relative_path(_), do: {:error, :invalid_path}

  @doc false
  @spec normalize_revision(term()) :: {:ok, :candidate | :base} | {:error, term()}
  def normalize_revision(revision) when revision in [:candidate, "candidate"],
    do: {:ok, :candidate}

  def normalize_revision(revision) when revision in [:base, "base"], do: {:ok, :base}
  def normalize_revision(_), do: {:error, :unsupported_revision}

  @doc false
  @spec validate_literal_query(term()) :: {:ok, String.t()} | {:error, term()}
  def validate_literal_query(query) when is_binary(query) do
    cond do
      query == "" ->
        {:error, :invalid_query}

      not String.valid?(query) ->
        {:error, :invalid_utf8}

      String.contains?(query, <<0>>) ->
        {:error, :invalid_query}

      byte_size(query) > @max_query_bytes ->
        {:error, :query_too_long}

      true ->
        {:ok, query}
    end
  end

  def validate_literal_query(_), do: {:error, :invalid_query}

  @doc false
  @spec normalize_limit(term()) :: {:ok, pos_integer()} | {:error, term()}
  def normalize_limit(nil), do: {:ok, @default_search_limit}

  def normalize_limit(limit) when is_integer(limit) and limit >= 1 and limit <= @max_search_limit,
    do: {:ok, limit}

  def normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> normalize_limit(n)
      _ -> {:error, :invalid_limit}
    end
  end

  def normalize_limit(_), do: {:error, :invalid_limit}

  @doc false
  @spec commit_for_revision(map(), :candidate | :base) :: String.t()
  def commit_for_revision(snapshot, :candidate),
    do: snapshot.candidate_commit || snapshot["candidate_commit"]

  def commit_for_revision(snapshot, :base), do: snapshot.base_commit || snapshot["base_commit"]

  @doc false
  @spec read_blob(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_blob(repo_path, commit, path)
      when is_binary(repo_path) and is_binary(commit) and is_binary(path) do
    object = commit <> ":" <> path

    with {:ok, type} <- git(repo_path, ["cat-file", "-t", object]),
         :ok <- require_blob(String.trim(type)),
         {:ok, content} <- git(repo_path, ["cat-file", "blob", object]),
         :ok <- reject_binary(content),
         :ok <- reject_oversized(content),
         :ok <- require_utf8(content) do
      {:ok, content}
    end
  end

  def read_blob(_, _, _), do: {:error, :invalid_read_args}

  @doc false
  @spec search_tree(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def search_tree(repo_path, commit, query, limit)
      when is_binary(repo_path) and is_binary(commit) and is_binary(query) and is_integer(limit) do
    # git grep with a commit-ish searches that tree (tracked files only).
    # -F literal, -I skip binary, -n line numbers, --full-name stable paths.
    # -- excludes pathspecs that could look like options.
    args = [
      "grep",
      "-n",
      "-F",
      "-I",
      "--full-name",
      "-e",
      query,
      commit,
      "--"
    ]

    case System.cmd("git", ["-C", repo_path | args], stderr_to_stdout: true) do
      {output, 0} ->
        parse_grep_matches(output, commit, limit)

      {_output, 1} ->
        # git grep exit 1 means no matches.
        {:ok, %{matches: [], match_count: 0, truncated: false}}

      {output, _code} ->
        {:error, {:search_failed, String.trim(output)}}
    end
  rescue
    _ -> {:error, :search_failed}
  end

  def search_tree(_, _, _, _), do: {:error, :invalid_search_args}

  defp parse_grep_matches(output, commit, limit) do
    lines =
      output
      |> String.split("\n", trim: true)

    {matches, truncated, _total_bytes} =
      Enum.reduce_while(lines, {[], false, 0}, fn line, {acc, _trunc, bytes} ->
        if length(acc) >= limit do
          {:halt, {acc, true, bytes}}
        else
          case parse_grep_line(line, commit) do
            {:ok, match} ->
              match_bytes = byte_size(match.path) + byte_size(match.text) + 16

              if bytes + match_bytes > @max_total_match_bytes do
                {:halt, {acc, true, bytes}}
              else
                {:cont, {[match | acc], false, bytes + match_bytes}}
              end

            :error ->
              {:cont, {acc, false, bytes}}
          end
        end
      end)

    matches = Enum.reverse(matches)

    {:ok,
     %{
       matches: matches,
       match_count: length(matches),
       truncated: truncated or length(lines) > length(matches)
     }}
  end

  defp parse_grep_line(line, commit) when is_binary(commit) do
    # When grepping a tree-ish, git prefixes each hit as commit:path:lineno:text.
    rest =
      case String.split_at(line, byte_size(commit) + 1) do
        {prefix, rest} when prefix == commit <> ":" -> rest
        _ -> line
      end

    # format: path:lineno:text  (paths with ':' are rejected by path validation)
    case Regex.run(~r/\A([^:]+):(\d+):(.*)\z/s, rest) do
      [_, path, line_no, text] ->
        with {:ok, path} <- validate_repo_relative_path(path),
             {n, ""} <- Integer.parse(line_no),
             true <- n >= 1,
             true <- String.valid?(text),
             true <- not String.contains?(text, <<0>>),
             text <- truncate_match_line(text) do
          {:ok, %{path: path, line: n, text: text}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp truncate_match_line(text) when byte_size(text) > @max_match_line_bytes do
    binary_part(text, 0, @max_match_line_bytes)
  end

  defp truncate_match_line(text), do: text

  defp require_blob("blob"), do: :ok
  defp require_blob("tree"), do: {:error, :not_a_blob}
  defp require_blob("commit"), do: {:error, :not_a_blob}
  defp require_blob(_), do: {:error, :missing_path}

  defp reject_binary(content) do
    if String.contains?(content, <<0>>), do: {:error, :binary_content}, else: :ok
  end

  defp reject_oversized(content) do
    if byte_size(content) > @max_content_bytes,
      do: {:error, :content_too_large},
      else: :ok
  end

  defp require_utf8(content) do
    if String.valid?(content), do: :ok, else: {:error, :invalid_utf8}
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, classify_git_error(String.trim(output))}
    end
  rescue
    _ -> {:error, :git_failed}
  end

  defp classify_git_error(msg) do
    cond do
      String.contains?(msg, "Not a valid object name") -> :missing_path
      String.contains?(msg, "does not exist") -> :missing_path
      String.contains?(msg, "exists on disk, but not in") -> :missing_path
      String.contains?(msg, "bad object") -> :missing_path
      true -> {:git_failed, msg}
    end
  end

  # -- Actions --------------------------------------------------------

  defmodule Read do
    @moduledoc """
    Read a single tracked blob from a review snapshot tree (candidate or base).

    Authority is the parent workspace lease (live owner process, or matching
    non-empty `task_id` plus principal/agent id). Opaque `review_snapshot_id`
    alone is never enough. Paths must be repo-relative; absolute paths,
    traversal, `.git` segments, and binary/non-UTF-8 content are rejected.
    """

    use Jido.Action,
      name: "coding_review_tree_read",
      description:
        "Read a tracked file from a commit-bound coding review snapshot (candidate or base tree)",
      category: "coding",
      tags: ["coding", "review", "git", "tree", "read"],
      schema: [
        review_snapshot_id: [
          type: :string,
          required: true,
          doc: "Opaque review snapshot id from open_review_snapshot"
        ],
        revision: [
          type: :string,
          required: true,
          doc: "Tree revision: \"candidate\" or \"base\""
        ],
        path: [
          type: :string,
          required: true,
          doc: "Repo-relative path of a tracked blob in the selected tree"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.ReviewTree
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        review_snapshot_id: :control,
        revision: :control,
        path: {:control, requires: [:path_traversal]}
      }
    end

    def effect_class, do: :read

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) when is_map(params) do
      review_snapshot_id = map_value(params, :review_snapshot_id)
      revision_raw = map_value(params, :revision)
      path_raw = map_value(params, :path)

      Actions.emit_started(__MODULE__, %{
        review_snapshot_id: review_snapshot_id,
        revision: revision_raw,
        path: path_raw
      })

      result =
        with :ok <- require_snapshot_id(review_snapshot_id),
             {:ok, revision} <- ReviewTree.normalize_revision(revision_raw),
             {:ok, path} <- ReviewTree.validate_repo_relative_path(path_raw),
             {:ok, snapshot} <-
               WorkspaceLeaseRegistry.resolve_review_snapshot(
                 review_snapshot_id,
                 caller_opts(context)
               ),
             {:ok, commit} <- require_commit(ReviewTree.commit_for_revision(snapshot, revision)),
             {:ok, repo_path} <- require_repo_path(map_value(snapshot, :repo_path)),
             {:ok, content} <- ReviewTree.read_blob(repo_path, commit, path) do
          %{
            review_snapshot_id: review_snapshot_id,
            revision: Atom.to_string(revision),
            commit: commit,
            path: path,
            content: content,
            size: byte_size(content)
          }
        end

      case result do
        %{} = ok ->
          Actions.emit_completed(__MODULE__, %{
            review_snapshot_id: review_snapshot_id,
            path: ok.path,
            size: ok.size
          })

          {:ok, ok}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp require_snapshot_id(id) when is_binary(id) and id != "", do: :ok
    defp require_snapshot_id(_), do: {:error, :invalid_review_snapshot_id}

    defp require_commit(commit) when is_binary(commit) and commit != "", do: {:ok, commit}
    defp require_commit(_), do: {:error, :invalid_snapshot}

    defp require_repo_path(path) when is_binary(path) and path != "", do: {:ok, path}
    defp require_repo_path(_), do: {:error, :invalid_snapshot}

    defp map_value(map, key), do: ReviewTree.map_param(map, key)
    defp caller_opts(context), do: ReviewTree.caller_context_opts(context)
  end

  defmodule Search do
    @moduledoc """
    Literal search across every tracked file in a review snapshot tree.

    Uses argv-based `git grep` against the snapshot's candidate or base commit
    so untracked files and `.git` internals are excluded by construction.
    Authority matches review snapshot resolve. Query and result set are
    length-bounded.
    """

    use Jido.Action,
      name: "coding_review_tree_search",
      description:
        "Literal search over a commit-bound coding review snapshot tree (candidate or base)",
      category: "coding",
      tags: ["coding", "review", "git", "tree", "search"],
      schema: [
        review_snapshot_id: [
          type: :string,
          required: true,
          doc: "Opaque review snapshot id from open_review_snapshot"
        ],
        revision: [
          type: :string,
          required: true,
          doc: "Tree revision: \"candidate\" or \"base\""
        ],
        query: [
          type: :string,
          required: true,
          doc: "Bounded literal search string (not a regex)"
        ],
        limit: [
          type: :integer,
          doc: "Max matches to return (1..100, default 20)"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.ReviewTree
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        review_snapshot_id: :control,
        revision: :control,
        query: {:control, requires: [:prompt_injection]},
        limit: :data
      }
    end

    def effect_class, do: :read

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) when is_map(params) do
      review_snapshot_id = map_value(params, :review_snapshot_id)
      revision_raw = map_value(params, :revision)
      query_raw = map_value(params, :query)
      limit_raw = map_value(params, :limit)

      Actions.emit_started(__MODULE__, %{
        review_snapshot_id: review_snapshot_id,
        revision: revision_raw
      })

      result =
        with :ok <- require_snapshot_id(review_snapshot_id),
             {:ok, revision} <- ReviewTree.normalize_revision(revision_raw),
             {:ok, query} <- ReviewTree.validate_literal_query(query_raw),
             {:ok, limit} <- ReviewTree.normalize_limit(limit_raw),
             {:ok, snapshot} <-
               WorkspaceLeaseRegistry.resolve_review_snapshot(
                 review_snapshot_id,
                 caller_opts(context)
               ),
             {:ok, commit} <- require_commit(ReviewTree.commit_for_revision(snapshot, revision)),
             {:ok, repo_path} <- require_repo_path(map_value(snapshot, :repo_path)),
             {:ok, search} <- ReviewTree.search_tree(repo_path, commit, query, limit) do
          %{
            review_snapshot_id: review_snapshot_id,
            revision: Atom.to_string(revision),
            commit: commit,
            query: query,
            limit: limit,
            matches: search.matches,
            match_count: search.match_count,
            truncated: search.truncated
          }
        end

      case result do
        %{} = ok ->
          Actions.emit_completed(__MODULE__, %{
            review_snapshot_id: review_snapshot_id,
            match_count: ok.match_count,
            truncated: ok.truncated
          })

          {:ok, ok}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp require_snapshot_id(id) when is_binary(id) and id != "", do: :ok
    defp require_snapshot_id(_), do: {:error, :invalid_review_snapshot_id}

    defp require_commit(commit) when is_binary(commit) and commit != "", do: {:ok, commit}
    defp require_commit(_), do: {:error, :invalid_snapshot}

    defp require_repo_path(path) when is_binary(path) and path != "", do: {:ok, path}
    defp require_repo_path(_), do: {:error, :invalid_snapshot}

    defp map_value(map, key), do: ReviewTree.map_param(map, key)
    defp caller_opts(context), do: ReviewTree.caller_context_opts(context)
  end

  @doc false
  def map_param(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  @doc false
  def caller_context_opts(context) do
    %{
      task_id: Arbor.Actions.Coding.Workspace.context_task_id(context),
      principal_id: Arbor.Actions.Coding.Workspace.context_principal_id(context)
    }
  end
end
