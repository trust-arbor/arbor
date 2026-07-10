defmodule Arbor.Scheduler.PipelinePaths do
  @moduledoc """
  Canonical path handling for signed scheduler pipelines.

  Pipeline manifests bind a logical root name plus a root-relative path. The
  configured root supplies the deployment-specific absolute path; resolving a
  pipeline follows symlinks and then verifies that the exact file remains under
  that root. Symlinks below an allowed root are rejected, even when they point
  to another location inside the root, so the reviewed pathname cannot be
  redirected after enrollment.
  """

  alias Arbor.Common.SafePath

  @type execution_paths :: %{
          path: Path.t(),
          caps_path: Path.t(),
          root_id: String.t(),
          relative_path: Path.t()
        }

  @spec resolve_pipeline(Path.t()) ::
          {:ok, execution_paths()}
          | {:error, :pipeline_not_found | {:caps_file_missing, Path.t()} | term()}
  def resolve_pipeline(path) when is_binary(path) do
    with :ok <- validate_input_path(path),
         {:ok, roots} <- configured_roots(),
         {:ok, pipeline} <- find_pipeline(path, roots),
         {:ok, caps_path} <- resolve_caps_path(pipeline) do
      {:ok, Map.put(pipeline, :caps_path, caps_path)}
    end
  end

  def resolve_pipeline(_), do: {:error, {:pipeline_path_rejected, :not_a_string}}

  @doc "Resolve an existing directory to the absolute real path used in an attestation."
  @spec resolve_workdir(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve_workdir(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    with :ok <- validate_path_text(path, :workdir_path_rejected),
         {:ok, real_path} <- resolve_real(expanded, :workdir_not_found),
         {:ok, %File.Stat{type: :directory}} <- File.stat(real_path) do
      {:ok, real_path}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:workdir_path_rejected, {:not_directory, type}}}
      {:error, {:workdir_path_rejected, _} = reason} -> {:error, reason}
      {:error, :workdir_not_found} -> {:error, :workdir_not_found}
      {:error, reason} -> {:error, {:workdir_path_rejected, reason}}
    end
  end

  def resolve_workdir(_), do: {:error, {:workdir_path_rejected, :not_a_string}}

  @doc "Verify that a signing-task target is the canonical sibling caps file."
  @spec verify_caps_target(Path.t(), execution_paths()) :: :ok | {:error, term()}
  def verify_caps_target(path, %{caps_path: expected}) when is_binary(path) do
    with :ok <- validate_path_text(path, :caps_path_rejected),
         {:ok, actual} <- resolve_real(Path.expand(path), :caps_file_missing) do
      if actual == expected,
        do: :ok,
        else: {:error, {:caps_path_rejected, :not_pipeline_sibling}}
    end
  end

  @doc "Read and SHA-256 hash the exact DOT bytes."
  @spec hash_file(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, {:pipeline_read_failed, reason}}
    end
  end

  defp configured_roots do
    case Application.get_env(:arbor_scheduler, :pipeline_roots) do
      roots when is_map(roots) and map_size(roots) > 0 -> normalize_roots(roots)
      nil -> {:error, :pipeline_roots_not_configured}
      _ -> {:error, :invalid_pipeline_roots_config}
    end
  end

  defp normalize_roots(roots) do
    roots
    |> Enum.sort_by(fn {root_id, _paths} -> inspect(root_id) end)
    |> Enum.reduce_while({:ok, []}, fn {root_id, paths}, {:ok, acc} ->
      with :ok <- validate_root_id(root_id),
           {:ok, entries} <- normalize_root_paths(root_id, List.wrap(paths)) do
        {:cont, {:ok, entries ++ acc}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, :pipeline_roots_not_configured}

      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.uniq_by(&{&1.id, &1.lexical, &1.real})
         |> Enum.sort_by(&{-byte_size(&1.real), &1.id})}

      error ->
        error
    end
  end

  defp normalize_root_paths(root_id, paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case normalize_root(root_id, path) do
        {:ok, root} -> {:cont, {:ok, [root | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_root(root_id, path) when is_binary(path) and path != "" do
    lexical = Path.expand(path)

    with {:ok, real} <- resolve_real(lexical, :not_found),
         {:ok, %File.Stat{type: :directory}} <- File.stat(real) do
      {:ok, %{id: root_id, lexical: lexical, real: real}}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_pipeline_root, root_id, {:not_directory, type}}}

      {:error, reason} ->
        {:error, {:invalid_pipeline_root, root_id, reason}}
    end
  end

  defp normalize_root(root_id, _path),
    do: {:error, {:invalid_pipeline_root, root_id, :not_a_path}}

  defp find_pipeline(path, roots) do
    matches =
      path
      |> candidate_paths(roots)
      |> Enum.flat_map(&match_candidate(&1, roots))
      |> Enum.uniq_by(&{&1.root_id, &1.relative_path, &1.path})

    case matches do
      [match] -> {:ok, match}
      [] -> classify_missing_or_rejected(path, roots)
      _ -> {:error, {:pipeline_path_rejected, :ambiguous_allowed_root}}
    end
  end

  defp candidate_paths(path, roots) do
    if Path.type(path) == :absolute do
      [Path.expand(path)]
    else
      cwd_candidate = Path.expand(path)

      root_candidates =
        Enum.flat_map(roots, fn root ->
          [Path.expand(path, root.lexical), Path.expand(path, root.real)]
        end)

      Enum.uniq([cwd_candidate | root_candidates])
    end
  end

  defp match_candidate(candidate, roots) do
    Enum.flat_map(roots, fn root ->
      case relative_under_root(candidate, root) do
        {:ok, relative} ->
          expected_real = Path.expand(relative, root.real)

          with {:ok, actual_real} <- resolve_real(candidate, :not_found),
               true <- actual_real == expected_real,
               true <- within?(actual_real, root.real),
               {:ok, %File.Stat{type: :regular}} <- File.stat(actual_real) do
            [
              %{
                path: actual_real,
                root_id: root.id,
                relative_path: relative
              }
            ]
          else
            _ -> []
          end

        :error ->
          []
      end
    end)
  end

  defp classify_missing_or_rejected(path, roots) do
    candidates = candidate_paths(path, roots)

    cond do
      Enum.any?(candidates, &File.exists?/1) ->
        {:error, {:pipeline_path_rejected, rejection_reason(candidates, roots)}}

      Path.type(path) == :absolute ->
        {:error, {:pipeline_path_rejected, :outside_allowed_roots}}

      true ->
        {:error, :pipeline_not_found}
    end
  end

  defp rejection_reason(candidates, roots) do
    if Enum.any?(candidates, fn candidate ->
         Enum.any?(roots, fn root -> relative_under_root(candidate, root) != :error end)
       end) do
      :symlink_or_non_regular_file
    else
      :outside_allowed_roots
    end
  end

  defp resolve_caps_path(%{path: pipeline_path, root_id: root_id, relative_path: relative}) do
    expected = String.replace_suffix(pipeline_path, ".dot", ".caps.json")

    cond do
      not File.exists?(expected) ->
        {:error, {:caps_file_missing, expected}}

      true ->
        with {:ok, real} <- resolve_real(expected, :caps_file_missing),
             true <- real == expected,
             {:ok, %File.Stat{type: :regular}} <- File.stat(real) do
          {:ok, real}
        else
          _ ->
            {:error,
             {:caps_path_rejected,
              %{root: root_id, path: String.replace_suffix(relative, ".dot", ".caps.json")}}}
        end
    end
  end

  defp relative_under_root(candidate, root) do
    cond do
      within?(candidate, root.lexical) -> {:ok, Path.relative_to(candidate, root.lexical)}
      within?(candidate, root.real) -> {:ok, Path.relative_to(candidate, root.real)}
      true -> :error
    end
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp validate_input_path(path) do
    with :ok <- validate_path_text(path, :pipeline_path_rejected),
         true <- Path.extname(path) == ".dot" do
      :ok
    else
      false -> {:error, {:pipeline_path_rejected, :not_dot_file}}
      {:error, _} = error -> error
    end
  end

  defp validate_path_text(path, wrapper) do
    case SafePath.validate(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {wrapper, reason}}
    end
  end

  defp validate_root_id(root_id)
       when is_binary(root_id) and root_id != "" do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, root_id),
      do: :ok,
      else: {:error, {:invalid_pipeline_root_id, root_id}}
  end

  defp validate_root_id(root_id), do: {:error, {:invalid_pipeline_root_id, root_id}}

  defp resolve_real(path, missing_reason) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, missing_reason}
    end
  end
end
