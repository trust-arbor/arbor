defmodule Mix.Tasks.Arbor.Hands.Cleanup do
  @shortdoc "Clean up a Hand's worktree and branch"
  @moduledoc """
  Removes a Hand's git worktree, branch, and directory after review/merge.

      $ mix arbor.hands.cleanup security-tests
      $ mix arbor.hands.cleanup security-tests --force
      $ mix arbor.hands.cleanup --all

  By default, only deletes the branch if it has been merged to main.
  Use `--force` to delete unmerged branches.

  ## Options

    * `--force` - Delete branch even if not merged to main
    * `--all` - Clean up all stopped hands that have summaries
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [force: :boolean, all: :boolean]
      )

    if opts[:all] do
      cleanup_all(opts)
    else
      name = List.first(positional)

      unless name do
        Mix.shell().error("Usage: mix arbor.hands.cleanup <name> [--force]")
        Mix.shell().error("       mix arbor.hands.cleanup --all [--force]")
        exit({:shutdown, 1})
      end

      cleanup_hand(name, opts)
    end
  end

  defp cleanup_hand(name, opts) do
    ensure_hand_stopped(name)
    ensure_hand_dir_exists(name)
    maybe_remove_worktree(name, opts)
    maybe_delete_branch(name, opts)

    # Remove hand directory
    File.rm_rf!(Hands.hand_dir(name))
    Mix.shell().info("Removed .arbor/hands/#{name}/")
    Mix.shell().info("Cleanup complete for '#{name}'.")
  end

  defp ensure_hand_stopped(name) do
    case Hands.find_hand(name) do
      :not_found ->
        :ok

      {type, _} ->
        Mix.shell().error(
          "Hand '#{name}' is still running (#{type}). Stop it first with: mix arbor.hands.stop #{name}"
        )

        exit({:shutdown, 1})
    end
  end

  defp ensure_hand_dir_exists(name) do
    unless File.dir?(Hands.hand_dir(name)) do
      Mix.shell().error("No hand directory found for '#{name}'")
      exit({:shutdown, 1})
    end
  end

  defp maybe_remove_worktree(name, opts) do
    unless Hands.has_worktree?(name), do: :ok

    case Hands.remove_worktree(name) do
      :ok ->
        Mix.shell().info("Removed worktree for '#{name}'")

      {:error, reason} ->
        Mix.shell().error(reason)
        handle_worktree_error(opts)
    end
  end

  defp handle_worktree_error(opts) do
    unless opts[:force] do
      exit({:shutdown, 1})
    end
  end

  defp maybe_delete_branch(name, opts) do
    branch = Hands.worktree_branch(name)

    case System.cmd("git", ["rev-parse", "--verify", branch], stderr_to_stdout: true) do
      {_, 0} -> delete_branch(name, branch, opts)
      _ -> :ok
    end
  end

  defp delete_branch(name, branch, opts) do
    if Hands.worktree_branch_merged?(name) do
      delete_merged_branch(name, branch)
    else
      delete_unmerged_branch(name, branch, opts)
    end
  end

  defp delete_merged_branch(name, branch) do
    case Hands.delete_worktree_branch(name) do
      :ok -> Mix.shell().info("Deleted merged branch #{branch}")
      {:error, reason} -> Mix.shell().error(reason)
    end
  end

  defp delete_unmerged_branch(name, branch, opts) do
    if opts[:force] do
      case Hands.delete_worktree_branch(name, force: true) do
        :ok -> Mix.shell().info("Force-deleted unmerged branch #{branch}")
        {:error, reason} -> Mix.shell().error(reason)
      end
    else
      Mix.shell().info(
        "Branch #{branch} has unmerged commits. Use --force to delete, or merge first."
      )
    end
  end

  defp cleanup_all(opts) do
    hands_dir = Hands.hands_dir()

    unless File.dir?(hands_dir) do
      Mix.shell().info("No hands directory found.")
      return_early()
    end

    candidates = find_cleanup_candidates(hands_dir)
    run_cleanup_candidates(candidates, opts)
  end

  defp find_cleanup_candidates(hands_dir) do
    hands_dir
    |> File.ls!()
    |> Enum.filter(fn name ->
      dir = Path.join(hands_dir, name)
      File.dir?(dir) && Hands.summary_exists?(name) && Hands.find_hand(name) == :not_found
    end)
  end

  defp run_cleanup_candidates([], _opts) do
    Mix.shell().info("No stopped hands with summaries to clean up.")
  end

  defp run_cleanup_candidates(candidates, opts) do
    Mix.shell().info("Cleaning up #{length(candidates)} hand(s)...")

    Enum.each(candidates, fn name ->
      Mix.shell().info("")
      Mix.shell().info("--- #{name} ---")
      cleanup_hand(name, opts)
    end)
  end

  defp return_early, do: :ok
end
