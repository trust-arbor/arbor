defmodule Arbor.Orchestrator.CodingPlan.ReadinessRoots do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.Plan

  @doc false
  @spec validate(Plan.t(), term(), term()) :: :ok | {:error, atom()}
  def validate(%Plan{} = plan, repo_roots, worktree_roots) do
    with {:ok, repo_roots} <- canonicalize_roots(repo_roots, :repo),
         {:ok, worktree_roots} <- canonicalize_roots(worktree_roots, :worktree),
         {:ok, repo_path} <- existing_directory(plan.repo_root, :repo_path),
         :ok <- inside_any?(repo_path, repo_roots, :repo_outside_root),
         :ok <- validate_worktree_base(plan.workspace_policy["worktree_base_dir"], worktree_roots) do
      _ = repo_path
      :ok
    end
  end

  def validate(_plan, _repo_roots, _worktree_roots), do: {:error, :invalid_plan}

  defp canonicalize_roots(roots, kind) when is_list(roots) and roots != [] do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case canonical_root(root) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        :error -> {:halt, {:error, root_error(kind)}}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, Enum.uniq(roots)}
      {:error, _reason} = error -> error
    end
  end

  defp canonicalize_roots(_roots, kind), do: {:error, root_error(kind)}

  defp canonical_root(root) when is_binary(root) do
    with :ok <- SafePath.validate(root),
         true <- SafePath.absolute?(root),
         {:ok, canonical} <- SafePath.resolve_real(root),
         true <- canonical != "/" and File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> :error
    end
  end

  defp canonical_root(_root), do: :error

  defp existing_directory(path, field) when not is_binary(path), do: {:error, field}

  defp existing_directory(path, field) do
    with :ok <- SafePath.validate(path),
         true <- SafePath.absolute?(path),
         {:ok, canonical} <- SafePath.resolve_real(path),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, field}
    end
  end

  defp inside_any?(path, roots, error) do
    if Enum.any?(roots, &contained?(&1, path)), do: :ok, else: {:error, error}
  end

  defp contained?(root, path) do
    case SafePath.resolve_within(path, root) do
      {:ok, ^path} -> true
      _ -> false
    end
  end

  defp validate_worktree_base(nil, _roots), do: :ok

  defp validate_worktree_base(path, roots) do
    with {:ok, canonical} <- existing_directory(path, :invalid_worktree_path),
         :ok <- inside_any?(canonical, roots, :worktree_outside_root) do
      :ok
    end
  end

  defp root_error(:repo), do: :invalid_repo_roots
  defp root_error(:worktree), do: :invalid_worktree_roots
end
