defmodule Arbor.AI.AcpMerge do
  @moduledoc """
  Git merge utilities for multi-agent worktree convergence.

  When multiple ACP agents work in parallel worktrees, their changes
  need to be merged back into the target branch. This module provides
  utilities for merging and collecting diffs from worktrees.
  """

  require Logger

  @doc """
  Merge a worktree branch back into the target branch.

  Returns `{:ok, merge_result}` on clean merge, `{:conflict, details}`
  when conflicts are detected, or `{:error, reason}` on failure.

  ## Options

  - `:cwd` — working directory for git commands (default: `File.cwd!()`)
  """
  @spec merge_worktree(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def merge_worktree(worktree_path, _target_branch, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case get_worktree_branch(worktree_path) do
      {:ok, branch} ->
        case System.cmd("git", ["merge", "--no-ff", branch, "-m", "Merge #{branch}"],
               cd: cwd,
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            {:ok, %{branch: branch, status: :clean}}

          {output, 1} ->
            if output =~ "CONFLICT" do
              files = parse_conflict_files(output)
              {:conflict, %{branch: branch, files: files, output: output}}
            else
              {:error, String.trim(output)}
            end

          {output, _} ->
            {:error, String.trim(output)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Collect diffs from multiple worktrees for comparison (without merging).

  Returns a list of diff summaries, one per worktree.
  """
  @spec collect_diffs([String.t()], keyword()) :: [map()]
  def collect_diffs(worktree_paths, opts \\ []) do
    base_branch = Keyword.get(opts, :base_branch, "main")

    Enum.map(worktree_paths, fn path ->
      case get_worktree_branch(path) do
        {:ok, branch} ->
          {output, _} =
            System.cmd("git", ["diff", "#{base_branch}...#{branch}"],
              cd: path,
              stderr_to_stdout: true
            )

          %{path: path, branch: branch, diff: output}

        {:error, reason} ->
          %{path: path, branch: nil, diff: "", error: reason}
      end
    end)
  end

  @doc """
  Check if a worktree has any uncommitted changes.
  """
  @spec worktree_dirty?(String.t()) :: boolean()
  def worktree_dirty?(path) do
    case System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> true
    end
  end

  # -- Private --

  defp get_worktree_branch(path) do
    case System.cmd("git", ["branch", "--show-current"], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        branch = String.trim(output)
        if branch == "", do: {:error, "detached HEAD in #{path}"}, else: {:ok, branch}

      {output, _} ->
        {:error, "failed to get branch for #{path}: #{String.trim(output)}"}
    end
  end

  defp parse_conflict_files(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "CONFLICT"))
    |> Enum.map(fn line ->
      case Regex.run(~r/Merge conflict in (.+)$/, line) do
        [_, file] -> String.trim(file)
        _ -> String.trim(line)
      end
    end)
  end
end
