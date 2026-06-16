defmodule Arbor.Persistence.DatabaseCase do
  @moduledoc """
  ExUnit case template for tests that need the durable Ecto Repo
  (`Arbor.Persistence.Repo`) with proper `Ecto.Adapters.SQL.Sandbox` isolation.

  Tag the test module `@moduletag :database` (so it's excluded from the default,
  no-database test lane) and `use Arbor.Persistence.DatabaseCase`.

  This template handles the setup that every `:database` test was previously
  open-coding inconsistently (some started the Repo, some called
  `Sandbox.checkout` against a Repo that was never started — the latter crashed
  with *"could not lookup Ecto repo … it was not started"*):

  - **Starts the Repo lazily**, only when a `:database` test actually runs, in
    `setup_all`. Doing it here rather than in app boot keeps the Repo's startup
    from interfering with non-database app initialization (e.g. `Signals.Store`).
  - **Skips the whole module** (rather than crashing) when the database is
    unreachable, so a missing/down database degrades to skipped, not red.
  - **Sets `:manual` Sandbox mode** and checks out a per-test connection via
    `start_owner!`/`stop_owner` — the modern API that ties the connection's
    ownership to a helper process stopped on exit. This avoids the
    `{:shared, pid}` "owner process died before the test ran" footgun that the
    earlier hand-rolled setup hit.

  ## Why this lives in `lib/` (not `test/support`)

  Umbrella apps don't share each other's `test/support` paths. `arbor_memory`'s
  `:database` tests need this helper and `arbor_memory` already depends on
  `arbor_persistence`, so the shared template lives in `lib/`. It is only ever
  exercised under ExUnit; in a release it's an inert module.

  ## Usage

      defmodule My.Thing.DatabaseTest do
        use Arbor.Persistence.DatabaseCase, async: false

        test "reads/writes through the durable Repo" do
          # Arbor.Persistence.Repo is started + a Sandbox connection is checked out
        end
      end
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Arbor.Persistence.Repo
    end
  end

  # How long to wait for the Repo's connection pool / sandbox owner to be alive
  # before giving up. Tens of ms is plenty under normal load; the generous
  # ceiling only matters on a heavily-loaded CI box.
  @repo_ready_timeout_ms 5_000
  @repo_ready_poll_ms 25

  setup_all do
    case ensure_repo_started() do
      {:ok, _pid} ->
        # The Repo is started UNLINKED (see ensure_repo_started/0): a linked
        # start would tie the Repo's lifetime to this setup_all callback's
        # short-lived process, so the FIRST module's teardown would kill the
        # Repo and a LATER module that got {:already_started, <dying pid>} would
        # then call Sandbox.mode/2 against a dead owner → `(EXIT) no process`.
        # That was the intermittent `set_manual_mode/0` crash. Unlinking +
        # waiting for the pool below makes the case tolerant of cross-module
        # startup ordering and restarts.
        case wait_for_repo_ready(@repo_ready_timeout_ms) do
          :ok ->
            set_manual_mode()

          {:error, reason} ->
            {:skip, "database not available: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:skip, "database not available: #{inspect(reason)}"}
    end
  end

  # Start the Repo if it isn't already, and ALWAYS return it unlinked from the
  # caller so it outlives this setup_all process. Returns {:ok, pid} once a live
  # Repo supervisor exists, or {:error, reason} if it can't be started.
  defp ensure_repo_started do
    case Arbor.Persistence.Repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Defensively unlink in case a prior caller in this process linked it.
        _ = Process.unlink(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Poll until the Repo's GenServer / connection pool is registered AND alive,
  # so the subsequent `Sandbox.mode(Repo, :manual)` (a GenServer.call into the
  # pool) can't race a not-yet-up or just-died owner.
  defp wait_for_repo_ready(timeout_ms) when timeout_ms <= 0 do
    if repo_alive?(), do: :ok, else: {:error, :repo_not_ready}
  end

  defp wait_for_repo_ready(timeout_ms) do
    if repo_alive?() do
      :ok
    else
      Process.sleep(@repo_ready_poll_ms)
      wait_for_repo_ready(timeout_ms - @repo_ready_poll_ms)
    end
  end

  defp repo_alive? do
    case GenServer.whereis(Arbor.Persistence.Repo) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  setup tags do
    # The owner process holds the checked-out connection; stopping it on exit
    # releases it and rolls back the test's transaction. `shared: true` (the
    # default for sync tests) lets processes the test spawns see the same
    # connection — needed by tests that drive GenServers/indexes.
    pid = Sandbox.start_owner!(Arbor.Persistence.Repo, shared: not (tags[:async] == true))
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  defp set_manual_mode do
    set_manual_mode(@repo_ready_timeout_ms)
  end

  # `Sandbox.mode/2` issues a GenServer.call into the connection pool. Even
  # after wait_for_repo_ready/1, the pool can briefly be unavailable across a
  # restart, so we retry on the `no process`/noproc exit instead of letting it
  # crash setup_all (which previously took down every test in the module). On a
  # genuinely-absent database the module degrades to skipped, not red.
  defp set_manual_mode(remaining_ms) when remaining_ms <= 0 do
    # Last attempt — let any error surface as a skip rather than a crash.
    try do
      Sandbox.mode(Arbor.Persistence.Repo, :manual)
      :ok
    catch
      :exit, reason -> {:skip, "database sandbox not ready: #{inspect(reason)}"}
    end
  end

  defp set_manual_mode(remaining_ms) do
    Sandbox.mode(Arbor.Persistence.Repo, :manual)
    :ok
  catch
    :exit, {:noproc, _} ->
      Process.sleep(@repo_ready_poll_ms)
      set_manual_mode(remaining_ms - @repo_ready_poll_ms)

    :exit, {:no_proc, _} ->
      Process.sleep(@repo_ready_poll_ms)
      set_manual_mode(remaining_ms - @repo_ready_poll_ms)
  end
end
