defmodule Arbor.Memory.TestBootstrap do
  @moduledoc """
  Starts the memory stores and durable knowledge-graph authority that
  `Arbor.Memory` needs under ExUnit.

  Call once from a consumer app's `test/test_helper.exs`:

      Arbor.Memory.TestBootstrap.start!()

  ## Why this exists

  `config/test.exs` sets `arbor_memory: start_children: false` so the suite
  cannot collide with a running dev server — the app's supervisor comes up
  empty, and `Application.ensure_all_started/1` is therefore not enough.

  Since the durable knowledge-graph authority landed (2026-08-05, `e4509485c` /
  `030f398af`), `Arbor.Memory.init_for_agent/1` admits that authority before
  starting an index, and `KnowledgeGraphStore` fails closed without it. Every
  consumer app's memory tests started failing `{:error, :store_unavailable}` —
  103 in `arbor_actions` alone — because the commit that introduced the
  requirement updated arbor_memory's own test files and swept no other app.

  Before this module, three apps hand-rolled three different partial versions of
  this setup and a fourth had none. That drift is the actual defect this
  prevents; the `store_unavailable` breakage was just what made it visible.

  ## Two things that cost time to discover

  **Starting the processes is not sufficient.** `Registry`,
  `KnowledgeGraphStore`, `IndexSupervisor` and `GoalStore` can all be alive and
  `get_graph/1` still returns `:store_unavailable`, because the real failure is
  inside the call, behind a catch-all rescue. What matters is the
  `BufferedStore`'s **backend config**.

  **The `Arbor.Memory.Test.DurableGraphAuthority` fixture's shape does not work
  here.** Its `backend: QueryableStore.ETS` + `collection:` + `ack_mode:
  :backend` combination fails for consumers; the production shape works. That
  fixture also asserts exclusive ownership to force `async: false`, which
  arbor_memory's own *graph* tests need for isolation and consumers do not —
  consumers only need an authority to exist. Keep using the fixture inside
  arbor_memory; use this module everywhere else.

  ## Why this lives in `lib/` (not `test/support`)

  Umbrella apps don't share each other's `test/support` paths, and four apps
  need this. Same reasoning and same precedent as
  `Arbor.Persistence.DatabaseCase`. It is only ever exercised under ExUnit; in a
  release it is an inert module.

  ## Scope

  Deliberately omits `Arbor.Memory.DistributedSync` — cluster sync in a test
  BEAM is never wanted. If a test needs it, start it explicitly.

  A test that does not exercise the knowledge graph can skip all of this with
  `Arbor.Memory.init_for_agent(agent_id, graph_enabled: false)`.
  """

  require Logger

  alias Arbor.Memory.Config
  alias Arbor.Memory.TestBootstrap.AdmissionBackend

  # Mirrors Arbor.Memory.Application's ensure_ets/1 calls. `:arbor_memory_goals`
  # is intentionally absent — GoalStore creates it in its own init/1.
  @tables [
    :arbor_memory_graphs,
    :arbor_working_memory,
    :arbor_memory_proposals,
    :arbor_preferences
  ]

  @authority_name :arbor_memory_durable

  @doc """
  Start the memory stores, ETS tables, and durable graph authority.

  Idempotent — safe to call from a `test_helper.exs` that may run more than
  once, and safe when some children are already up.

  Returns `:ok` when the work was done, or `:skipped` when
  `Arbor.Memory.Supervisor` is not running (e.g. under `mix test --no-start`).
  It returns a distinguishable value rather than silently pretending to have
  succeeded — a bootstrap that no-ops quietly is how "nothing ran" gets
  mistaken for "everything is fine", which is the failure mode that produced
  this module.

  Raises when the supervisor is running but a child cannot be started, since
  that leaves the suite in a state where every memory test fails with a
  misleading error.

  ## Options

  - `:authority` — when `false`, skip starting `:arbor_memory_durable`.
  - `:admission` — when `false`, skip mutation admission, the bootstrap
    admission backend, and the async writer supervisor. Default `true`.

  Pass `authority: false` in an app whose tests need to **own** that name
  per-test. `:arbor_memory_durable` is a single global registered name, so a
  suite-wide instance blocks any test that swaps in a deliberately-failing
  backend to simulate an outage — `start_supervised!` becomes a no-op and the
  matching `stop_supervised!` then raises "not found". arbor_agent's `SeedTest`
  does exactly this, and arbor_memory's own `DurableGraphAuthority` fixture
  refuses outright via `assert_unowned!/0`.

  The alternative — having those tests stop a child this module started — is
  the shared-supervisor anti-pattern that causes restart-intensity cascades.
  Don't. Opt out instead.
  """
  @spec start!(keyword()) :: :ok | :skipped
  def start!(opts \\ []) do
    _ = Application.ensure_all_started(:arbor_memory)

    if Process.whereis(Arbor.Memory.Supervisor) do
      ensure_tables()
      if Keyword.get(opts, :authority, true), do: ensure_authority!()
      if Keyword.get(opts, :admission, true), do: ensure_admission!()
      ensure_children!()
      :ok
    else
      Logger.warning(
        "[Arbor.Memory.TestBootstrap] Arbor.Memory.Supervisor is not running; " <>
          "memory-backed tests will fail with {:error, :store_unavailable}"
      )

      :skipped
    end
  end

  defp ensure_tables do
    for table <- @tables, :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end

    :ok
  rescue
    # A concurrent creator won the race; the table exists either way.
    ArgumentError -> :ok
  end

  # The production shape from Arbor.Memory.Application. write_mode: :sync rather
  # than :async so a test's write is readable on the next line without waiting
  # on a flush.
  defp ensure_authority! do
    if Process.whereis(@authority_name) do
      :ok
    else
      spec =
        {Arbor.Persistence.BufferedStore,
         name: @authority_name,
         backend: Application.get_env(:arbor_memory, :persistence_backend),
         write_mode: :sync}

      case Supervisor.start_child(Arbor.Memory.Supervisor, spec) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
        {:error, reason} -> raise "TestBootstrap: durable authority failed: #{inspect(reason)}"
      end
    end
  end

  defp ensure_admission! do
    for spec <- admission_children() do
      start_optional_child!(spec)
    end

    case Arbor.Memory.MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      {:error, reason} ->
        raise "TestBootstrap: mutation admission not ready: #{inspect(reason)}"
    end

    if Process.whereis(Arbor.Memory.AsyncWriter.Supervisor) do
      :ok
    else
      raise "TestBootstrap: async writer supervisor is not running"
    end
  end

  defp ensure_children! do
    for spec <- children() do
      start_optional_child!(spec)
    end

    :ok
  end

  defp start_optional_child!(spec) do
    case Supervisor.start_child(Arbor.Memory.Supervisor, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> raise "TestBootstrap: #{inspect(spec)} failed: #{inspect(reason)}"
    end
  end

  defp admission_children do
    [
      {AdmissionBackend, [agent_name: AdmissionBackend.name(), allow_test_bootstrap: true]},
      {Registry, keys: :unique, name: Arbor.Memory.MutationAdmission.Registry},
      {Arbor.Memory.MutationAdmission.GuardianSupervisor, []},
      {Arbor.Memory.MutationAdmission,
       [
         target: %{
           namespace: Config.fixed_mutation_admission_namespace(),
           backend: AdmissionBackend,
           opts: [agent_name: AdmissionBackend.name()]
         }
       ]},
      {Arbor.Memory.AsyncWriter.Supervisor, []}
    ]
  end

  defp children do
    [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.ArchiveCursorSigner, []},
      {Arbor.Memory.Provenance, []},
      {Arbor.Memory.Proposal.Store, []},
      {Arbor.Memory.KnowledgeGraphStore, []},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ]
  end
end
