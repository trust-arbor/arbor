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
    # Check if hand is still running
    case Hands.find_hand(name) do
      :not_found ->
        :ok

      {type, _} ->
        Mix.shell().error(
          "Hand '#{name}' is still running (#{type}). Stop it first with: mix arbor.hands.stop #{name}"
        )

        exit({:shutdown, 1})
    end

    hand_dir = Hands.hand_dir(name)

    unless File.dir?(hand_dir) do
      Mix.shell().error("No hand directory found for '#{name}'")
      exit({:shutdown, 1})
    end

    # Remove worktree
    if Hands.has_worktree?(name) do
      case Hands.remove_worktree(name) do
        :ok ->
          Mix.shell().info("Removed worktree for '#{name}'")

        {:error, reason} ->
          Mix.shell().error(reason)

          unless opts[:force] do
            exit({:shutdown, 1})
          end
      end
    end

    # Delete branch
    branch = Hands.worktree_branch(name)

    case System.cmd("git", ["rev-parse", "--verify", branch], stderr_to_stdout: true) do
      {_, 0} ->
        if Hands.worktree_branch_merged?(name) do
          case Hands.delete_worktree_branch(name) do
            :ok ->
              Mix.shell().info("Deleted merged branch #{branch}")

            {:error, reason} ->
              Mix.shell().error(reason)
          end
        else
          if opts[:force] do
            case Hands.delete_worktree_branch(name, force: true) do
              :ok ->
                Mix.shell().info("Force-deleted unmerged branch #{branch}")

              {:error, reason} ->
                Mix.shell().error(reason)
            end
          else
            Mix.shell().info(
              "Branch #{branch} has unmerged commits. Use --force to delete, or merge first."
            )
          end
        end

      _ ->
        :ok
    end

    # Remove hand directory
    File.rm_rf!(hand_dir)
    Mix.shell().info("Removed .arbor/hands/#{name}/")
    Mix.shell().info("Cleanup complete for '#{name}'.")
  end

  defp cleanup_all(opts) do
    hands_dir = Hands.hands_dir()

    if File.dir?(hands_dir) do
      candidates =
        hands_dir
        |> File.ls!()
        |> Enum.filter(fn name ->
          dir = Path.join(hands_dir, name)
          File.dir?(dir) && Hands.summary_exists?(name) && Hands.find_hand(name) == :not_found
        end)

      if candidates == [] do
        Mix.shell().info("No stopped hands with summaries to clean up.")
      else
        Mix.shell().info("Cleaning up #{length(candidates)} hand(s)...")

        Enum.each(candidates, fn name ->
          Mix.shell().info("")
          Mix.shell().info("--- #{name} ---")
          cleanup_hand(name, opts)
        end)
      end
    else
      Mix.shell().info("No hands directory found.")
    end
  end
end
