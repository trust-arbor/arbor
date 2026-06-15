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

  setup_all do
    case Arbor.Persistence.Repo.start_link() do
      {:ok, _pid} -> set_manual_mode()
      {:error, {:already_started, _pid}} -> set_manual_mode()
      {:error, reason} -> {:skip, "database not available: #{inspect(reason)}"}
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
    Sandbox.mode(Arbor.Persistence.Repo, :manual)
    :ok
  end
end
