defmodule Arbor.Actions.FileProvenance do
  @moduledoc """
  Durable taint sidecar for workspace files written through `Arbor.Actions.File`.

  A file written under an untrusted (or otherwise labeled) context keeps that
  label on later reads, including in another process or session. Sidecars bind
  `Arbor.Contracts.Security.TaintEnvelope` to the content SHA-256 so later
  reads still match after SafePath vs absolute-join spelling differences.

  Fail-closed:
  - an agent write with unknown taint persists `:untrusted`
  - a present but unverifiable sidecar is `:hostile`, never `nil` / `:trusted`
  - missing sidecar on an ordinary in-workspace file falls back to
    `Arbor.Actions.Taint.path_provenance/1` so user-created workspace files
    stay unlabeled rather than trusted
  - cloned repos, linked worktrees, and paths outside the agent's workspace
    are `:untrusted` even with no sidecar (TrojanForge / repository poisoning)
  """

  alias Arbor.Actions.Taint, as: ActionTaint
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @sidecar_suffix ".arbor-taint"
  @foreign_root_marker ".arbor-foreign-root"
  @git_metadata_marker "arbor-foreign-root"
  @levels [:trusted, :derived, :untrusted, :hostile]

  @doc "Sidecar path beside `file_path` (hidden from default directory listings)."
  @spec sidecar_path(String.t()) :: String.t()
  def sidecar_path(file_path) when is_binary(file_path) do
    Path.join(Path.dirname(file_path), "." <> Path.basename(file_path) <> @sidecar_suffix)
  end

  @doc """
  Persist provenance after a successful write.

  System writes with no agent and no taint label leave no sidecar. Agent
  writes without a usable label persist `:untrusted`.
  """
  @spec persist(String.t(), binary(), map(), atom()) :: :ok | {:error, atom()}
  def persist(path, content, context, mode)
      when is_binary(path) and is_binary(content) and is_map(context) and is_atom(mode) do
    case taint_for_write(context) do
      :none ->
        :ok

      {:ok, taint} ->
        taint = maybe_join_existing(path, taint, mode)
        write_sidecar(path, content, taint)
    end
  rescue
    _ -> {:error, :provenance_persist_failed}
  catch
    _, _ -> {:error, :provenance_persist_failed}
  end

  def persist(_path, _content, _context, _mode), do: {:error, :provenance_persist_failed}

  @doc """
  Persist a tree-level untrusted marker on a foreign root.

  Individual cloned files have no per-file sidecar. Markers go into git
  metadata (`.git/arbor-foreign-root` or the worktree gitdir) so they do
  not dirty the checkout; non-git trees keep `.arbor-foreign-root` at the
  root. Leased coding worktrees are **not** marked this way — writing into
  the gitdir breaks object-backed snapshot identity. Clones, linked
  worktrees that are not this process's checkout, nested git trees inside
  a provided workspace, and paths outside the workspace are labeled by
  structural detection instead.
  """
  @spec mark_foreign_root(String.t(), String.t()) :: :ok | {:error, atom()}
  def mark_foreign_root(root, source) when is_binary(root) and is_binary(source) do
    payload = %{"level" => "untrusted", "source" => source}

    with {:ok, json} <- Jason.encode(payload),
         :ok <- File.write(write_marker_path(root), json) do
      :ok
    else
      _ -> {:error, :foreign_root_marker_failed}
    end
  rescue
    _ -> {:error, :foreign_root_marker_failed}
  catch
    _, _ -> {:error, :foreign_root_marker_failed}
  end

  def mark_foreign_root(_root, _source), do: {:error, :foreign_root_marker_failed}

  @doc "Resolve the durable level for `path` plus on-disk (or supplied) bytes."
  @spec resolve(String.t(), binary() | nil) :: Taint.level() | nil
  @spec resolve(String.t(), binary() | nil, keyword()) :: Taint.level() | nil
  def resolve(path, content, opts \\ [])

  def resolve(path, content, opts) when is_binary(path) and is_list(opts) do
    cond do
      sidecar_path?(path) or foreign_root_marker_path?(path) ->
        :untrusted

      is_binary(content) ->
        resolve_candidates([path], content, opts)

      true ->
        resolve_path(path, opts)
    end
  end

  def resolve(_path, _content, _opts), do: :untrusted

  @doc "Resolve provenance from a read-path param, trying expanded spellings."
  @spec resolve_path(term()) :: Taint.level() | nil
  @spec resolve_path(term(), keyword()) :: Taint.level() | nil
  def resolve_path(path, opts \\ [])

  def resolve_path(path, opts) when is_binary(path) and path != "" and is_list(opts) do
    if sidecar_path?(path) or foreign_root_marker_path?(path) do
      :untrusted
    else
      candidates =
        [path, Path.expand(path)]
        |> Enum.uniq()
        |> Enum.filter(&regular_file?/1)

      case candidates do
        [] ->
          unlabeled_fallback(path, opts)

        [found | _] ->
          case File.read(found) do
            {:ok, content} -> resolve_candidates([found | candidates], content, opts)
            _ -> :untrusted
          end
      end
    end
  end

  def resolve_path(path, opts) when is_list(opts), do: unlabeled_fallback(path, opts)

  defp resolve_candidates(paths, content, opts) do
    Enum.reduce_while(paths, unlabeled_fallback(List.first(paths), opts), fn path, fallback ->
      case lookup_sidecar(path, content) do
        :missing ->
          {:cont, fallback || unlabeled_fallback(path, opts)}

        {:ok, level} ->
          {:halt, level}
      end
    end)
  end

  defp unlabeled_fallback(path, opts) when is_binary(path) do
    workspace = provenance_workspace(opts)

    cond do
      foreign_root?(path) -> :untrusted
      git_foreign?(path) -> :untrusted
      nested_git?(path, workspace) -> :untrusted
      outside_workspace?(path, workspace) -> :untrusted
      true -> ActionTaint.path_provenance(path)
    end
  end

  defp unlabeled_fallback(path, _opts), do: ActionTaint.path_provenance(path)

  defp provenance_workspace(opts) when is_list(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" -> workspace
      _ -> nil
    end
  end

  defp outside_workspace?(_path, nil), do: false

  defp outside_workspace?(path, workspace) when is_binary(path) and is_binary(workspace) do
    expanded_path = Path.expand(path)
    expanded_ws = Path.expand(workspace)

    not (expanded_path == expanded_ws or
           String.starts_with?(expanded_path, expanded_ws <> "/"))
  end

  # Linked worktrees are always foreign. A clone with a remote is foreign
  # unless it *is* this process's checkout — otherwise every file in the
  # agent's own workspace git would be labeled untrusted and would break
  # the sidecar-missing-stays-unlabeled contract from the file-taint PR.
  # Nested clones inside a provided workspace are handled separately.
  defp git_foreign?(path) when is_binary(path) do
    case enclosing_git(path) do
      {:worktree, _root} ->
        true

      {:repo, root} ->
        git_has_remote?(root) and not same_git_root?(root, process_git_root())

      :none ->
        false
    end
  end

  defp git_foreign?(_), do: false

  defp nested_git?(path, workspace) when is_binary(path) and is_binary(workspace) do
    case enclosing_git(path) do
      {kind, root} when kind in [:repo, :worktree] ->
        expanded_root = Path.expand(root)
        expanded_ws = Path.expand(workspace)

        expanded_root != expanded_ws and
          String.starts_with?(expanded_root, expanded_ws <> "/")

      :none ->
        false
    end
  end

  defp nested_git?(_path, _workspace), do: false

  defp process_git_root do
    enclosing_git(File.cwd!())
  rescue
    _ -> :none
  end

  defp same_git_root?(root, {:repo, cwd_root}),
    do: Path.expand(root) == Path.expand(cwd_root)

  defp same_git_root?(root, {:worktree, cwd_root}),
    do: Path.expand(root) == Path.expand(cwd_root)

  defp same_git_root?(_root, :none), do: false

  defp enclosing_git(path) do
    start = if dir_exists?(path), do: path, else: Path.dirname(path)
    walk_git(Path.expand(start))
  end

  defp walk_git(dir) do
    git = Path.join(dir, ".git")

    cond do
      regular_file?(git) ->
        {:worktree, dir}

      dir_exists?(git) ->
        {:repo, dir}

      true ->
        parent = Path.dirname(dir)

        if parent == dir do
          :none
        else
          walk_git(parent)
        end
    end
  end

  defp git_has_remote?(repo_root) when is_binary(repo_root) do
    config = Path.join([repo_root, ".git", "config"])

    case File.read(config) do
      {:ok, body} -> String.contains?(body, "[remote ")
      _ -> false
    end
  end

  defp foreign_root?(path) when is_binary(path) do
    start = if dir_exists?(path), do: path, else: Path.dirname(path)
    walk_foreign_root(Path.expand(start))
  end

  defp foreign_root?(_), do: false

  defp walk_foreign_root(dir) do
    if regular_file?(Path.join(dir, @foreign_root_marker)) or git_metadata_marker?(dir) do
      true
    else
      parent = Path.dirname(dir)

      if parent == dir do
        false
      else
        walk_foreign_root(parent)
      end
    end
  end

  defp git_metadata_marker?(dir) do
    git = Path.join(dir, ".git")

    cond do
      dir_exists?(git) ->
        regular_file?(Path.join(git, @git_metadata_marker))

      regular_file?(git) ->
        case worktree_gitdir(git) do
          {:ok, gitdir} -> regular_file?(Path.join(gitdir, @git_metadata_marker))
          :error -> false
        end

      true ->
        false
    end
  end

  defp write_marker_path(root) do
    git = Path.join(root, ".git")

    cond do
      regular_file?(git) ->
        case worktree_gitdir(git) do
          {:ok, gitdir} -> Path.join(gitdir, @git_metadata_marker)
          :error -> Path.join(root, @foreign_root_marker)
        end

      dir_exists?(git) ->
        Path.join(git, @git_metadata_marker)

      true ->
        Path.join(root, @foreign_root_marker)
    end
  end

  defp worktree_gitdir(git_file) do
    case File.read(git_file) do
      {:ok, body} ->
        case Regex.run(~r/^gitdir:\s*(.+)$/m, body) do
          [_, gitdir] ->
            path = gitdir |> String.trim() |> Path.expand(Path.dirname(git_file))
            if dir_exists?(path), do: {:ok, path}, else: :error

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp foreign_root_marker_path?(path) when is_binary(path) do
    name = Path.basename(path)
    name in [@foreign_root_marker, @git_metadata_marker]
  end

  defp dir_exists?(path) do
    case File.dir?(path) do
      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp lookup_sidecar(path, content) do
    sidecar = sidecar_path(path)

    case File.read(sidecar) do
      {:error, :enoent} ->
        :missing

      {:error, _reason} ->
        {:ok, :hostile}

      {:ok, json} ->
        {:ok, level_from_sidecar(json, payload(path, content))}
    end
  end

  defp level_from_sidecar(json, payload) do
    with {:ok, persisted} <- Jason.decode(json),
         {:ok, taint, status} <- TaintEnvelope.resolve(persisted, payload),
         true <- status in [:verified, :invalid_durable_provenance, :legacy_unlabeled] do
      if status == :verified, do: taint.level, else: fail_closed_level(taint)
    else
      _ -> :hostile
    end
  rescue
    _ -> :hostile
  catch
    _, _ -> :hostile
  end

  defp fail_closed_level(%Taint{level: level}) when level in @levels and level != :trusted do
    level
  end

  defp fail_closed_level(_), do: :untrusted

  defp write_sidecar(path, content, taint) do
    with {:ok, envelope} <- TaintEnvelope.new(payload(path, content), taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope),
         {:ok, json} <- Jason.encode(persisted),
         :ok <- File.write(sidecar_path(path), json) do
      :ok
    else
      _ -> {:error, :provenance_persist_failed}
    end
  end

  defp payload(_path, content) do
    # Bind the sidecar to content bytes only. Path spelling can differ between
    # write (SafePath-normalized) and a later-process absolute join.
    %{"content_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)}
  end

  defp taint_for_write(context) do
    case extract_context_taint(context) do
      {:ok, taint} ->
        {:ok, taint}

      :missing ->
        if agent_write?(context) do
          label_taint(:untrusted, "file_write_unknown_provenance")
        else
          :none
        end
    end
  end

  defp extract_context_taint(context) do
    raw = Map.get(context, :taint) || Map.get(context, "taint")

    cond do
      is_nil(raw) ->
        :missing

      match?(%Taint{}, raw) ->
        Taint.canonicalize(raw)

      raw in @levels ->
        label_taint(raw, "file_write")

      is_map(raw) ->
        Taint.canonicalize(raw)

      true ->
        :missing
    end
    |> case do
      {:ok, taint} -> {:ok, taint}
      {:error, _reason} -> label_taint(:untrusted, "file_write_unknown_provenance")
      :missing -> :missing
    end
  end

  defp label_taint(level, source) when level in @levels and is_binary(source) do
    Taint.new(%{
      level: level,
      sensitivity: if(level in [:untrusted, :hostile], do: :restricted, else: :internal),
      sanitizations: 0,
      confidence: :unverified,
      source: source,
      chain: []
    })
  end

  defp agent_write?(context) do
    agent = Map.get(context, :agent_id) || Map.get(context, "agent_id")
    is_binary(agent) and agent != ""
  end

  defp maybe_join_existing(path, taint, :append) do
    sidecar = sidecar_path(path)

    case File.read(sidecar) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, persisted} ->
            case TaintEnvelope.decode_persisted(persisted) do
              {:ok, envelope} ->
                case Taint.join(envelope.taint, taint) do
                  {:ok, joined} -> joined
                  _ -> taint
                end

              _ ->
                case Taint.join(Taint.invalid_durable_provenance(), taint) do
                  {:ok, joined} -> joined
                  _ -> taint
                end
            end

          _ ->
            taint
        end

      _ ->
        taint
    end
  end

  defp maybe_join_existing(_path, taint, _mode), do: taint

  defp sidecar_path?(path) when is_binary(path) do
    String.ends_with?(Path.basename(path), @sidecar_suffix)
  end

  defp regular_file?(path) do
    case File.regular?(path) do
      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
