defmodule Arbor.Orchestrator.CodingPlan.WorkspaceScope do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.Plan

  @doc false
  @spec normalize(Plan.t(), term(), term()) :: {:ok, Plan.t()} | {:error, term()}
  def normalize(%Plan{} = plan, configured_repo_roots, configured_worktree_roots) do
    with {:ok, repo_roots} <- canonicalize_configured_roots(configured_repo_roots, :repo),
         {:ok, worktree_roots} <-
           canonicalize_configured_roots(configured_worktree_roots, :worktree),
         {:ok, requested_repo_path} <-
           resolve_scoped_path(plan.repo_root, repo_roots, :repo_path),
         {:ok, repo_path} <- resolve_git_top_level(requested_repo_path, repo_roots),
         {:ok, worktree_base_dir} <-
           resolve_worktree_base(plan.workspace_policy["worktree_base_dir"], worktree_roots),
         plan_map = Plan.to_map(plan),
         workspace_policy =
           Map.put(plan_map["workspace_policy"], "worktree_base_dir", worktree_base_dir),
         {:ok, canonical_plan} <-
           Plan.new(
             plan_map
             |> Map.put("repo_root", repo_path)
             |> Map.put("workspace_policy", workspace_policy)
           ) do
      {:ok, canonical_plan}
    end
  end

  def normalize(_plan, _configured_repo_roots, _configured_worktree_roots),
    do: {:error, :invalid_plan}

  defp canonicalize_configured_roots(roots, kind) when is_list(roots) and roots != [] do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case canonicalize_configured_root(root, kind) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, canonical |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp canonicalize_configured_roots(_roots, kind),
    do: {:error, {:invalid_coding_roots, kind}}

  defp canonicalize_configured_root(root, kind) do
    with :ok <- SafePath.validate(root),
         true <- SafePath.absolute?(root),
         {:ok, canonical} <- SafePath.resolve_real(root),
         true <- canonical != "/" and File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, {:invalid_coding_root, kind}}
    end
  end

  defp resolve_scoped_path(path, roots, field) do
    with :ok <- validate_absolute_path(path, field),
         {:ok, canonical} <- resolve_existing_directory(path, field),
         :ok <- ensure_within_configured_roots(canonical, roots, field) do
      {:ok, canonical}
    end
  end

  defp validate_absolute_path(path, field) do
    with :ok <- SafePath.validate(path),
         true <- SafePath.absolute?(path) do
      :ok
    else
      _ -> {:error, {:invalid_coding_path, field}}
    end
  end

  defp resolve_existing_directory(path, field) do
    case SafePath.resolve_real(path) do
      {:ok, canonical} when canonical != "/" ->
        if File.dir?(canonical),
          do: {:ok, canonical},
          else: {:error, {:invalid_coding_path, field}}

      _ ->
        {:error, {:invalid_coding_path, field}}
    end
  end

  defp ensure_within_configured_roots(path, roots, field) do
    if Enum.any?(roots, &contained_in?(&1, path)) do
      :ok
    else
      {:error, {:coding_path_outside_roots, field}}
    end
  end

  defp contained_in?(root, path) do
    case SafePath.resolve_within(path, root) do
      {:ok, ^path} -> true
      _ -> false
    end
  end

  defp resolve_git_top_level(repo_path, repo_roots) do
    case System.cmd("git", ["-C", repo_path, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        git_root = String.trim(output)

        with :ok <- validate_absolute_path(git_root, :repo_path),
             {:ok, canonical_git_root} <- resolve_existing_directory(git_root, :repo_path),
             :ok <- ensure_within_configured_roots(canonical_git_root, repo_roots, :repo_path) do
          {:ok, canonical_git_root}
        else
          {:error, {:coding_path_outside_roots, :repo_path}} ->
            {:error, :git_root_outside_coding_roots}

          _ ->
            {:error, :invalid_git_repository}
        end

      {_output, _status} ->
        {:error, :invalid_git_repository}
    end
  rescue
    _ -> {:error, :invalid_git_repository}
  catch
    :exit, _ -> {:error, :invalid_git_repository}
  end

  defp resolve_worktree_base(nil, worktree_roots), do: {:ok, List.first(worktree_roots)}

  defp resolve_worktree_base(path, worktree_roots),
    do: resolve_scoped_path(path, worktree_roots, :worktree_base_dir)
end
