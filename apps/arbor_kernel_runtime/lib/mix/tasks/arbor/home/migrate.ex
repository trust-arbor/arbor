defmodule Mix.Tasks.Arbor.Home.Migrate do
  use Boundary, classify_to: Arbor.KernelRuntime.DevTools
  @shortdoc "Move state an older daemon wrote under ~/.arbor/distribution back to ~/.arbor"
  @moduledoc """
  One-time migration for installs that ran the 2026-10-07 daemon launcher.

      $ mix arbor.home.migrate            # dry run: print the plan, change nothing
      $ mix arbor.home.migrate --apply    # perform it (the daemon must be stopped)

  That launcher booted the daemon with HOME set to its private cookie
  directory, so the daemon read and wrote `~/.arbor/...` state (security
  master key, capability revocation ledger, workspace retention, skills and
  more) under `~/.arbor/distribution/.arbor/` instead. The gated launcher
  boots the daemon with the real HOME, and `mix arbor.start` refuses to
  launch until that legacy tree is gone.

  Policy: files only in the legacy tree move back; legacy files identical to
  the current copy are dropped; when both differ, the legacy copy wins (it is
  what the daemon actually used) and the current copy is kept as
  `<name>.pre-home-migration-<YYYYMMDD of its mtime>`. Nothing is deleted
  that is not byte-identical to a kept copy. `~/.arbor/distribution/.erlang.cookie`
  is not part of the legacy tree and stays where it is. Symlinks, special
  files, file/directory clashes and a SQLite database present in both trees
  block the whole migration.

  `--apply` holds the lifecycle lock and refuses while a managed daemon is
  alive. It stops at the first failed operation and reports what was done.

  ## Options

    * `--apply` - perform the plan instead of printing it
    * `--arbor-home PATH` - operate on another Arbor home (default `~/.arbor`)
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.HomeMigration
  alias Mix.Tasks.Arbor.HomeMigrationCore, as: Core

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [apply: :boolean, arbor_home: :string])

    if rest != [] or invalid != [] do
      Mix.raise("Usage: mix arbor.home.migrate [--apply] [--arbor-home PATH]")
    end

    home = opts |> Keyword.get(:arbor_home, Config.arbor_home()) |> Path.expand()

    if Keyword.get(opts, :apply, false) do
      apply_locked(home)
    else
      dry_run(home)
    end
  end

  defp dry_run(home) do
    with {:ok, plan} <- plan_or_report(home) do
      print_plan(plan)

      if Core.applicable?(plan) do
        Mix.shell().info("\nDry run: nothing changed. Stop the daemon, then re-run with --apply.")
      else
        Mix.shell().error("\nDry run: the blocked entries must be resolved before --apply.")
      end
    end
  end

  defp apply_locked(home) do
    case Config.with_lock(fn -> apply_admitted(home) end, home) do
      {:refuse, reason, detail} ->
        Mix.shell().error(Config.describe_lock_refusal(reason, detail))
        exit({:shutdown, 1})

      _ ->
        :ok
    end
  end

  # Plan again under the lock: the dry run may be stale by now.
  defp apply_admitted(home) do
    case Core.admit_apply(daemon_check(home)) do
      :ok ->
        with {:ok, plan} <- plan_or_report(home) do
          print_plan(plan)
          apply_plan(plan, home)
        end

      {:refuse, {:daemon_running, node}} ->
        fail("The Arbor daemon #{node} is running. Stop it first: ./bin/mix arbor.stop")

      {:refuse, :daemon_state_unverified} ->
        fail(
          "Cannot verify that the managed Arbor daemon is stopped; refusing to move key files."
        )
    end
  end

  defp apply_plan(plan, home) do
    if Core.applicable?(plan) do
      case HomeMigration.apply_plan(plan, home) do
        {:ok, done} ->
          Mix.shell().info(
            "\nApplied #{length(done)} operations. #{Config.legacy_home_root(home)} is gone."
          )

        {:error, %{done: done, failed: {op, reason}, remaining: remaining}} ->
          fail("""

          Stopped at #{inspect(op)}: #{inspect(reason)}.
          Completed #{length(done)} operations before it:
          #{Enum.map_join(done, "\n", &("  " <> inspect(&1)))}
          Not attempted (#{length(remaining)}):
          #{Enum.map_join(remaining, "\n", &("  " <> inspect(&1)))}

          Nothing was rolled back. Fix the cause and re-run the dry run; it plans
          from what is on disk now.
          """)
      end
    else
      fail("\nNothing applied: resolve the blocked entries first.")
    end
  end

  defp plan_or_report(home) do
    case HomeMigration.plan(home) do
      {:ok, plan} ->
        Mix.shell().info("Legacy daemon state: #{Config.legacy_home_root(home)}")
        Mix.shell().info("Destination:         #{home}\n")
        {:ok, plan}

      :absent ->
        Mix.shell().info(
          "No legacy daemon state under #{Config.legacy_home_root(home)}. Nothing to do."
        )

        :absent

      {:error, reason} ->
        fail("Could not read the legacy daemon state: #{inspect(reason)}")
    end
  end

  defp print_plan(plan), do: Enum.each(Core.describe(plan), fn line -> Mix.shell().info(line) end)

  defp daemon_check(home) do
    case Config.read_metadata(home) do
      {:ok, meta} -> Config.verify_pid_as_arbor_node(meta.pid)
      :absent -> legacy_pid_check(home)
      {:error, :malformed} -> :unverified
    end
  end

  defp legacy_pid_check(home) do
    case Config.read_pid(home) do
      :absent -> :absent
      {:ok, pid} -> Config.verify_pid_as_arbor_node(pid)
      {:error, :malformed} -> :unverified
    end
  end

  defp fail(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
