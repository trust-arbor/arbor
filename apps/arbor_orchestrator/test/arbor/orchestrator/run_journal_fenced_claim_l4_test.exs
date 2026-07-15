defmodule Arbor.Orchestrator.RunJournalFencedClaimL4Test.FencedNodeRestartStore do
  @moduledoc false
  # Deterministic Store: structured Record CAS + code-owned :node_restart.
  use GenServer

  alias Arbor.Contracts.Persistence.Record

  def durability_class(_opts), do: :node_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts) do
    GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
  end

  def get(key, opts) do
    GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  end

  def list(opts) do
    GenServer.call(Keyword.fetch!(opts, :name), :list)
  end

  def delete(key, opts) do
    GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
  end

  def compare_and_swap(key, expected, replacement, opts) do
    GenServer.call(Keyword.fetch!(opts, :name), {:compare_and_swap, key, expected, replacement})
  end

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    case apply_put(Map.get(state.data, key, :absent), key, value) do
      {:ok, stored} ->
        {:reply, :ok, %{state | data: Map.put(state.data, key, stored)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.data, key) do
      {:ok, {:tombstone, _}} -> {:reply, {:error, :not_found}, state}
      {:ok, value} -> {:reply, {:ok, value}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    keys =
      state.data
      |> Enum.reject(fn {_k, v} -> match?({:tombstone, _}, v) end)
      |> Enum.map(fn {k, _} -> k end)

    {:reply, {:ok, keys}, state}
  end

  def handle_call({:delete, key}, _from, state) do
    case Map.get(state.data, key) do
      %Record{generation: gen} ->
        {:reply, :ok, %{state | data: Map.put(state.data, key, {:tombstone, gen})}}

      {:tombstone, _} = t ->
        {:reply, :ok, %{state | data: Map.put(state.data, key, t)}}

      nil ->
        {:reply, :ok, state}

      _plain ->
        {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
    end
  end

  def handle_call({:compare_and_swap, key, expected, replacement}, _from, state) do
    case cas(Map.get(state.data, key, :absent), key, expected, replacement) do
      {:ok, stored} ->
        {:reply, {:ok, stored}, %{state | data: Map.put(state.data, key, stored)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Test-only: plant unstructured durable bytes without Record fencing.
  def handle_call({:put_unstructured, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  defp apply_put(:absent, key, %Record{} = record) do
    if record.key == key do
      now = DateTime.utc_now()
      {:ok, %{record | generation: 1, revision: 1, updated_at: now}}
    else
      {:error, :key_mismatch}
    end
  end

  defp apply_put({:tombstone, prev_gen}, key, %Record{} = record)
       when is_integer(prev_gen) and prev_gen >= 0 do
    if record.key == key do
      now = DateTime.utc_now()
      {:ok, %{record | generation: prev_gen + 1, revision: 1, updated_at: now}}
    else
      {:error, :key_mismatch}
    end
  end

  defp apply_put(%Record{} = current, key, %Record{} = record) do
    if current.key == key and record.key == key do
      now = DateTime.utc_now()

      {:ok,
       %{
         record
         | id: current.id,
           key: current.key,
           generation: current.generation,
           revision: current.revision + 1,
           inserted_at: current.inserted_at || record.inserted_at,
           updated_at: now
       }}
    else
      {:error, :key_mismatch}
    end
  end

  defp apply_put(_other, _key, value), do: {:ok, value}

  defp cas(:absent, key, :not_found, %Record{} = replacement) do
    if replacement.key == key do
      now = DateTime.utc_now()
      {:ok, %{replacement | generation: 1, revision: 1, updated_at: now}}
    else
      {:error, :key_mismatch}
    end
  end

  defp cas(:absent, _key, {:value, _}, _replacement), do: {:error, :conflict}

  defp cas(%Record{} = current, key, {:value, %Record{} = expected}, %Record{} = replacement) do
    cond do
      current.key != key or expected.key != key or replacement.key != key ->
        {:error, :key_mismatch}

      current.generation != expected.generation or current.revision != expected.revision ->
        {:error, :conflict}

      true ->
        now = DateTime.utc_now()

        {:ok,
         %{
           replacement
           | id: current.id,
             key: current.key,
             generation: current.generation,
             revision: current.revision + 1,
             inserted_at: current.inserted_at || replacement.inserted_at,
             updated_at: now
         }}
    end
  end

  defp cas(_current, _key, _expected, _replacement), do: {:error, :conflict}
end

defmodule Arbor.Orchestrator.RunJournalFencedClaimL4Test.AppRestartCASStore do
  @moduledoc false
  # Structured CAS like FencedNodeRestartStore, but application_restart class.
  use GenServer

  alias Arbor.Contracts.Persistence.Record

  def durability_class(_opts), do: :application_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts),
    do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})

  def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})

  def compare_and_swap(key, expected, replacement, opts) do
    GenServer.call(Keyword.fetch!(opts, :name), {:compare_and_swap, key, expected, replacement})
  end

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def handle_call(request, from, state) do
    # Reuse the node-restart store's CAS/put semantics by delegating to the same
    # private logic via a sibling process shape — implement identically.
    Arbor.Orchestrator.RunJournalFencedClaimL4Test.FencedNodeRestartStore.handle_call(
      request,
      from,
      state
    )
  end
end

defmodule Arbor.Orchestrator.RunJournalFencedClaimL4Test.NodeRestartNoCASStore do
  @moduledoc false
  use GenServer

  def durability_class(_opts), do: :node_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
  def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.data, key) do
      {:ok, v} -> {:reply, {:ok, v}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
  end
end

defmodule Arbor.Orchestrator.RunJournalFencedClaimL4Test.AppRestartNoCASStore do
  @moduledoc false
  use GenServer

  def durability_class(_opts), do: :application_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
  def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.data, key) do
      {:ok, v} -> {:reply, {:ok, v}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
  end
end

defmodule Arbor.Orchestrator.RunJournalFencedClaimL4Test do
  @moduledoc """
  L4B1 fenced distributed recovery claims — focused regression suite.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.JobRegistry
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RecoveryCoordinator
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunJournalFencedClaimL4Test.AppRestartCASStore
  alias Arbor.Orchestrator.RunJournalFencedClaimL4Test.AppRestartNoCASStore
  alias Arbor.Orchestrator.RunJournalFencedClaimL4Test.FencedNodeRestartStore
  alias Arbor.Orchestrator.RunJournalFencedClaimL4Test.NodeRestartNoCASStore
  alias Arbor.Persistence

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, suffix: suffix}
  end

  describe "durability_status fencing flags" do
    test "node_restart + CAS reports fenced_claim and cross_node_atomic_recovery", %{
      suffix: suffix
    } do
      {journal, _store} =
        start_journal_with_store(FencedNodeRestartStore, suffix, "nr_cas",
          local_node: :local_a@test
        )

      st = RunJournal.durability_status(server: journal)
      assert st.durable == true
      assert st.durability_class == :node_restart
      assert st.fenced_claim == true
      assert st.cross_node_atomic_recovery == true
    end

    test "application_restart + CAS reports fenced_claim only", %{suffix: suffix} do
      {journal, _store} =
        start_journal_with_store(AppRestartCASStore, suffix, "ar_cas", local_node: :local_ar@test)

      st = RunJournal.durability_status(server: journal)
      assert st.durable == true
      assert st.durability_class == :application_restart
      assert st.fenced_claim == true
      assert st.cross_node_atomic_recovery == false
    end

    test "node_restart without CAS does not claim distributed recovery", %{suffix: suffix} do
      {journal, _store} =
        start_journal_with_store(NodeRestartNoCASStore, suffix, "nr_nocas",
          local_node: :local_nr@test
        )

      st = RunJournal.durability_status(server: journal)
      assert st.durable == true
      assert st.durability_class == :node_restart
      assert st.fenced_claim == false
      assert st.cross_node_atomic_recovery == false
    end

    test "application_restart without CAS does not claim fencing", %{suffix: suffix} do
      {journal, _store} =
        start_journal_with_store(AppRestartNoCASStore, suffix, "ar_nocas",
          local_node: :local_ar_nocas@test
        )

      st = RunJournal.durability_status(server: journal)
      assert st.durable == true
      assert st.durability_class == :application_restart
      assert st.fenced_claim == false
      assert st.cross_node_atomic_recovery == false
    end
  end

  describe "fenced concurrent claim" do
    test "exactly one winner across isolated journals; loser hot refreshes", %{suffix: suffix} do
      store_name = :"l4b_shared_store_#{suffix}"
      node_a = :claim_a@test
      node_b = :claim_b@test
      remote = :remote_owner@other

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      journal_a = :"l4b_j_a_#{suffix}"
      journal_b = :"l4b_j_b_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: journal_a,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_a,
                 ets_table: :"l4b_hot_a_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: node_a
               ]
             ]}
        })

      run_id = "l4b_fence_run_#{suffix}"
      now = DateTime.utc_now()

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :interrupted,
                   total_nodes: 2,
                   completed_count: 1,
                   started_at: now,
                   last_heartbeat: now,
                   owner_node: nil,
                   source_node: remote
                 },
                 server: journal_a
               )

      {:ok, _} =
        start_supervised(%{
          id: journal_b,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_b,
                 ets_table: :"l4b_hot_b_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: node_b
               ]
             ]}
        })

      st_a = RunJournal.durability_status(server: journal_a)
      assert st_a.cross_node_atomic_recovery == true

      parent = self()

      tasks =
        for {journal, node, idx} <- [{journal_a, node_a, 1}, {journal_b, node_b, 2}] do
          Task.async(fn ->
            send(parent, {:ready, idx})

            receive do
              :go -> :ok
            after
              5_000 -> flunk("start barrier timeout")
            end

            RunJournal.claim_for_recovery(run_id, node, server: journal)
          end)
        end

      for _ <- 1..2, do: assert_receive({:ready, _}, 5_000)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      wins = Enum.filter(results, &match?({:ok, %Record{}}, &1))
      losses = Enum.reject(results, &match?({:ok, %Record{}}, &1))

      assert length(wins) == 1
      assert length(losses) == 1
      assert match?({:error, :claim_conflict}, hd(losses))

      {:ok, %Record{} = winner} = hd(wins)
      assert winner.status == :recovering
      assert to_string(winner.owner_node) in [to_string(node_a), to_string(node_b)]

      assert {:ok, %PersistenceRecord{data: data}} =
               Persistence.get(store_name, FencedNodeRestartStore, run_id)

      assert data["status"] == "recovering"
      assert data["owner_node"] in [to_string(node_a), to_string(node_b)]

      loser_journal =
        if to_string(winner.owner_node) == to_string(node_a), do: journal_b, else: journal_a

      assert {:ok, %Record{} = loser_hot} = RunJournal.get_record(run_id, server: loser_journal)
      assert loser_hot.status == :recovering
      assert to_string(loser_hot.owner_node) == to_string(winner.owner_node)

      winner_journal = if loser_journal == journal_a, do: journal_b, else: journal_a
      assert {:ok, %Record{} = winner_hot} = RunJournal.get_record(run_id, server: winner_journal)
      assert winner_hot.status == :recovering
      assert to_string(winner_hot.owner_node) == to_string(winner.owner_node)
    end

    test "remote-source claim succeeds only on fenced node_restart; claim-on-behalf denied", %{
      suffix: suffix
    } do
      remote = :"peer@other-node"
      local = :local_claim@test

      {j_fenced, _} =
        start_journal_with_store(FencedNodeRestartStore, suffix, "remote_ok", local_node: local)

      run_id = "l4b_remote_src_#{suffix}"

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :interrupted,
                   started_at: DateTime.utc_now(),
                   owner_node: nil,
                   source_node: remote
                 },
                 server: j_fenced
               )

      assert {:error, :cross_node_claim_unfenced} =
               RunJournal.claim_for_recovery(run_id, :other@host, server: j_fenced)

      assert {:ok, %Record{status: :interrupted}} =
               RunJournal.get_record(run_id, server: j_fenced)

      assert {:ok, %Record{status: :recovering, owner_node: ^local}} =
               RunJournal.claim_for_recovery(run_id, local, server: j_fenced)

      {j_ar, _} =
        start_journal_with_store(AppRestartCASStore, suffix, "remote_ar", local_node: local)

      run_id_ar = "l4b_remote_ar_#{suffix}"

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id_ar,
                   pipeline_id: run_id_ar,
                   status: :interrupted,
                   started_at: DateTime.utc_now(),
                   owner_node: nil,
                   source_node: remote
                 },
                 server: j_ar
               )

      assert RunJournal.durability_status(server: j_ar).cross_node_atomic_recovery == false

      assert {:error, :ambiguous_remote_row} =
               RunJournal.claim_for_recovery(run_id_ar, local, server: j_ar)

      {j_nocas, _} =
        start_journal_with_store(NodeRestartNoCASStore, suffix, "remote_nocas", local_node: local)

      run_id_nc = "l4b_remote_nc_#{suffix}"

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id_nc,
                   pipeline_id: run_id_nc,
                   status: :interrupted,
                   started_at: DateTime.utc_now(),
                   owner_node: nil,
                   source_node: remote
                 },
                 server: j_nocas
               )

      assert {:error, :ambiguous_remote_row} =
               RunJournal.claim_for_recovery(run_id_nc, local, server: j_nocas)
    end

    test "unstructured durable value fails closed on fenced claim", %{suffix: suffix} do
      store_name = :"l4b_unstruct_store_#{suffix}"
      journal_name = :"l4b_unstruct_journal_#{suffix}"
      local = :local_u@test
      run_id = "l4b_unstruct_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: :"l4b_unstruct_hot_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local
               ]
             ]}
        })

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :interrupted,
                   started_at: DateTime.utc_now(),
                   owner_node: nil,
                   source_node: local
                 },
                 server: journal_name
               )

      # Corrupt durable authority to an unversioned plain map (legacy shape).
      assert :ok =
               GenServer.call(
                 store_name,
                 {:put_unstructured, run_id,
                  %{"run_id" => run_id, "pipeline_id" => run_id, "status" => "interrupted"}}
               )

      assert {:error, :unstructured_durable_record} =
               RunJournal.claim_for_recovery(run_id, local, server: journal_name)

      # Hot must not fabricate recovering ownership after fail-closed claim.
      assert {:ok, %Record{status: :interrupted}} =
               RunJournal.get_record(run_id, server: journal_name)
    end

    test "local application_restart eligibility preserved without CAS", %{suffix: suffix} do
      local = Kernel.node()

      {journal_name, _store} =
        start_journal_with_store(AppRestartNoCASStore, suffix, "local_ar", local_node: local)

      st = RunJournal.durability_status(server: journal_name)
      assert st.durable == true
      assert st.durability_class == :application_restart
      assert st.fenced_claim == false
      assert st.cross_node_atomic_recovery == false

      run_id = "l4b_local_ar_#{suffix}"

      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :interrupted,
                   started_at: DateTime.utc_now(),
                   owner_node: nil,
                   source_node: local
                 },
                 server: journal_name
               )

      assert {:ok, %Record{status: :recovering, owner_node: ^local}} =
               RunJournal.claim_for_recovery(run_id, local, server: journal_name)

      assert :ok =
               RecoveryCoordinator.automatic_recovery_eligibility(%{
                 durable: true,
                 durability_class: :application_restart,
                 mode: :durable_declared
               })
    end
  end

  describe "RecoveryCoordinator nodedown gate" do
    test "application_restart fixture does not mutate remote owner on nodedown", %{
      suffix: suffix
    } do
      store_name = :"l4b_rc_ar_store_#{suffix}"
      journal_name = :"l4b_rc_ar_journal_#{suffix}"
      coord_name = :"l4b_rc_ar_coord_#{suffix}"
      remote = :dead_peer@other
      local = Kernel.node()
      run_id = "l4b_rc_ar_run_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {AppRestartNoCASStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: :"l4b_rc_ar_hot_#{suffix}",
                 backend: AppRestartNoCASStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local
               ]
             ]}
        })

      jopts = [server: journal_name]

      assert :ok =
               PipelineStatus.put(
                 %{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: DateTime.utc_now(),
                   total_nodes: 1,
                   completed_count: 0,
                   owner_node: remote,
                   source_node: remote
                 },
                 jopts
               )

      recovery_root = Path.join(System.tmp_dir!(), "l4b_rc_ar_root_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      {:ok, coord} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: jopts,
                 recovery_root: recovery_root,
                 delay_ms: 60_000
               ]
             ]}
        })

      st = RecoveryCoordinator.status(coord_name)
      assert st.automatic_recovery == true
      assert st.cross_node_atomic_recovery == false

      send(coord, {:nodedown, remote})
      _ = RecoveryCoordinator.status(coord_name)

      entry = PipelineStatus.get(run_id, jopts)
      assert entry.status == :running
      assert to_string(entry.owner_node) == to_string(remote)
      assert RecoveryCoordinator.status(coord_name).pending == 0
    end

    test "node_restart+CAS nodedown mutates journal to exact interrupted state", %{
      suffix: suffix
    } do
      store_name = :"l4b_rc_nr_store_#{suffix}"
      journal_name = :"l4b_rc_nr_journal_#{suffix}"
      coord_name = :"l4b_rc_nr_coord_#{suffix}"
      remote = :dead_fenced@other
      local = Kernel.node()
      run_id = "l4b_rc_nr_run_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: :"l4b_rc_nr_hot_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local
               ]
             ]}
        })

      jopts = [server: journal_name]

      assert :ok =
               PipelineStatus.put(
                 %{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: DateTime.utc_now(),
                   total_nodes: 1,
                   completed_count: 0,
                   owner_node: remote,
                   source_node: remote
                 },
                 jopts
               )

      recovery_root = Path.join(System.tmp_dir!(), "l4b_rc_nr_root_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      {:ok, coord} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: jopts,
                 recovery_root: recovery_root,
                 # Delay discover; nodedown still schedules recover_next immediately.
                 # Without execution_principal, recover_next leaves interrupted (no claim).
                 delay_ms: 60_000
               ]
             ]}
        })

      st = RecoveryCoordinator.status(coord_name)
      assert st.automatic_recovery == true
      assert st.cross_node_atomic_recovery == true
      assert st.fenced_claim == true

      send(coord, {:nodedown, remote})
      # Drain nodedown + recover_next (auth unavailable → leave interrupted).
      _ = RecoveryCoordinator.status(coord_name)

      entry = PipelineStatus.get(run_id, jopts)
      assert entry.status == :interrupted
      assert entry.owner_node == nil

      assert %Record{status: :interrupted, owner_node: nil} =
               PipelineStatus.get_record(run_id, jopts)

      assert {:ok, %PersistenceRecord{data: data}} =
               Persistence.get(store_name, FencedNodeRestartStore, run_id)

      assert data["status"] == "interrupted"
      assert data["owner_node"] in [nil, ""]
    end

    test "concurrent remote interrupt+claim elects one owner; loser cannot revert recovering",
         %{
           suffix: suffix
         } do
      store_name = :"l4b_race_store_#{suffix}"
      remote = :dead_race@other
      node_a = :race_a@test
      node_b = :race_b@test
      run_id = "l4b_race_run_#{suffix}"
      journal_a = :"l4b_race_ja_#{suffix}"
      journal_b = :"l4b_race_jb_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_a,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_a,
                 ets_table: :"l4b_race_hot_a_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: node_a
               ]
             ]}
        })

      # Seed remote-owned running; journal B rehydrates from shared durable store.
      assert :ok =
               RunJournal.put(
                 %Record{
                   run_id: run_id,
                   pipeline_id: run_id,
                   status: :running,
                   started_at: DateTime.utc_now(),
                   total_nodes: 1,
                   completed_count: 0,
                   owner_node: remote,
                   source_node: remote
                 },
                 server: journal_a
               )

      {:ok, _} =
        start_supervised(%{
          id: journal_b,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_b,
                 ets_table: :"l4b_race_hot_b_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: node_b
               ]
             ]}
        })

      parent = self()

      # Race full takeover: interrupt then claim on each survivor journal.
      tasks =
        for {journal, node, idx} <- [{journal_a, node_a, 1}, {journal_b, node_b, 2}] do
          Task.async(fn ->
            send(parent, {:ready, idx})

            receive do
              :go -> :ok
            after
              5_000 -> flunk("barrier timeout")
            end

            interrupt = RunJournal.mark_interrupted(run_id, server: journal)

            claim =
              case interrupt do
                :ok -> RunJournal.claim_for_recovery(run_id, node, server: journal)
                err -> err
              end

            {interrupt, claim}
          end)
        end

      for _ <- 1..2, do: assert_receive({:ready, _}, 5_000)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      claim_wins =
        Enum.filter(results, fn
          {:ok, {:ok, %Record{status: :recovering}}} -> true
          _ -> false
        end)

      assert length(claim_wins) == 1

      # Canonical durable must be recovering with exactly one owner — never interrupted after a claim win.
      assert {:ok, %PersistenceRecord{data: data}} =
               Persistence.get(store_name, FencedNodeRestartStore, run_id)

      assert data["status"] == "recovering"
      assert data["owner_node"] in [to_string(node_a), to_string(node_b)]

      # Loser (or any subsequent writer) must not revert durable recovering → interrupted.
      loser_journal =
        if data["owner_node"] == to_string(node_a), do: journal_b, else: journal_a

      winner_journal = if loser_journal == journal_a, do: journal_b, else: journal_a

      # Refresh loser hot to the durable recovering owner (simulates late observation).
      assert {:ok, %Record{status: :recovering}} =
               RunJournal.get_record(run_id, server: winner_journal)

      # Direct fenced interrupt against recovering durable must fail closed.
      # Seed loser hot with remote-owned running shape via put is blocked by
      # terminal/nonterminal rules — instead re-fetch after claim conflict path:
      # call mark_interrupted on the journal that still sees remote ownership by
      # re-putting is wrong; use the winner journal's recovering row observation
      # on the loser after rehydrate from durable.
      :ok = stop_supervised(loser_journal)

      {:ok, _} =
        start_supervised(%{
          id: :"#{loser_journal}_re",
          start:
            {RunJournal, :start_link,
             [
               [
                 name: loser_journal,
                 ets_table: :"l4b_race_hot_loser2_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: if(loser_journal == journal_a, do: node_a, else: node_b)
               ]
             ]}
        })

      assert {:ok, %Record{status: :recovering}} =
               RunJournal.get_record(run_id, server: loser_journal)

      assert {:error, :interrupt_conflict} =
               RunJournal.mark_interrupted(run_id, server: loser_journal)

      assert {:ok, %PersistenceRecord{data: still}} =
               Persistence.get(store_name, FencedNodeRestartStore, run_id)

      assert still["status"] == "recovering"
      assert still["owner_node"] == data["owner_node"]

      assert {:ok, %Record{status: :recovering, owner_node: owner}} =
               RunJournal.get_record(run_id, server: loser_journal)

      assert to_string(owner) == data["owner_node"]
    end

    test "ownerless remote-source stale writer cannot revert a recovering claim", %{
      suffix: suffix
    } do
      store_name = :"l4b_ownerless_store_#{suffix}"
      journal_a = :"l4b_ownerless_ja_#{suffix}"
      journal_b = :"l4b_ownerless_jb_#{suffix}"
      node_a = :ownerless_a@test
      node_b = :ownerless_b@test
      remote = :ownerless_source@other
      run_id = "l4b_ownerless_#{suffix}"

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      for {journal, table, local} <- [
            {journal_a, :"l4b_ownerless_hot_a_#{suffix}", node_a},
            {journal_b, :"l4b_ownerless_hot_b_#{suffix}", node_b}
          ] do
        {:ok, _} =
          start_supervised(%{
            id: journal,
            start:
              {RunJournal, :start_link,
               [
                 [
                   name: journal,
                   ets_table: table,
                   backend: FencedNodeRestartStore,
                   store_name: store_name,
                   start_store: false,
                   local_node: local
                 ]
               ]}
          })
      end

      ownerless_remote = %Record{
        run_id: run_id,
        pipeline_id: run_id,
        status: :running,
        started_at: DateTime.utc_now(),
        total_nodes: 1,
        owner_node: nil,
        source_node: remote
      }

      assert :ok = RunJournal.put(ownerless_remote, server: journal_a)

      # Journal B started before the seed, so give it the same stale ownerless
      # hot view without changing durable authority after the claim below.
      assert :ok = RunJournal.put(ownerless_remote, server: journal_b)
      assert :ok = RunJournal.mark_interrupted(run_id, server: journal_a)

      assert {:ok, %Record{status: :recovering, owner_node: ^node_a}} =
               RunJournal.claim_for_recovery(run_id, node_a, server: journal_a)

      # B still sees ownerless remote-source :running. This used to take the
      # ordinary put path and overwrite A's recovering CAS.
      assert {:ok, %Record{status: :running, owner_node: nil}} =
               RunJournal.get_record(run_id, server: journal_b)

      assert {:error, :interrupt_conflict} =
               RunJournal.mark_interrupted(run_id, server: journal_b)

      assert {:ok, %PersistenceRecord{data: durable}} =
               Persistence.get(store_name, FencedNodeRestartStore, run_id)

      assert durable["status"] == "recovering"
      assert durable["owner_node"] == to_string(node_a)

      assert {:ok, %Record{status: :recovering, owner_node: ^node_a}} =
               RunJournal.get_record(run_id, server: journal_b)
    end

    test "nodedown does not mutate or enqueue legacy JobRegistry rows", %{suffix: suffix} do
      store_name = :"l4b_legacy_store_#{suffix}"
      journal_name = :"l4b_legacy_journal_#{suffix}"
      coord_name = :"l4b_legacy_coord_#{suffix}"
      remote = :legacy_peer@other
      local = Kernel.node()
      legacy_run = "l4b_legacy_only_#{suffix}"
      jobs_store = :arbor_orchestrator_jobs

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: :"l4b_legacy_hot_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: local
               ]
             ]}
        })

      jopts = [server: journal_name]

      # Seed legacy-only remote-owned running row (no current journal entry).
      entry = %JobRegistry.Entry{
        pipeline_id: legacy_run,
        run_id: legacy_run,
        graph_id: "legacy_graph",
        started_at: DateTime.utc_now(),
        completed_count: 0,
        total_nodes: 1,
        status: :running,
        source_node: remote,
        owner_node: remote,
        last_heartbeat: DateTime.utc_now(),
        node_durations: %{}
      }

      assert :ok = Arbor.Persistence.BufferedStore.put(legacy_run, entry, name: jobs_store)

      on_exit(fn ->
        try do
          Arbor.Persistence.BufferedStore.delete(legacy_run, name: jobs_store)
        catch
          :exit, _ -> :ok
        end
      end)

      recovery_root = Path.join(System.tmp_dir!(), "l4b_legacy_root_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      {:ok, coord} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: jopts,
                 recovery_root: recovery_root,
                 delay_ms: 60_000
               ]
             ]}
        })

      st = RecoveryCoordinator.status(coord_name)
      assert st.cross_node_atomic_recovery == true

      send(coord, {:nodedown, remote})
      status_after = RecoveryCoordinator.status(coord_name)

      assert status_after.pending == 0

      # Legacy row unchanged — still running under remote owner.
      legacy = JobRegistry.get(legacy_run)
      assert legacy != nil
      assert legacy.status == :running
      assert to_string(legacy.owner_node) == to_string(remote)

      # Current journal never adopted the legacy identity.
      assert {:error, :not_found} = RunJournal.get_record(legacy_run, server: journal_name)
    end

    test "fenced capability preserves local legacy stale cleanup", %{suffix: suffix} do
      store_name = :"l4b_local_legacy_store_#{suffix}"
      journal_name = :"l4b_local_legacy_journal_#{suffix}"
      coord_name = :"l4b_local_legacy_coord_#{suffix}"
      legacy_run = "l4b_local_legacy_#{suffix}"
      jobs_store = :arbor_orchestrator_jobs
      now = DateTime.utc_now()
      {dead_pid, dead_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_pid, :normal}, 1_000

      {:ok, _} =
        start_supervised(%{
          id: store_name,
          start: {FencedNodeRestartStore, :start_link, [[name: store_name]]}
        })

      {:ok, _} =
        start_supervised(%{
          id: journal_name,
          start:
            {RunJournal, :start_link,
             [
               [
                 name: journal_name,
                 ets_table: :"l4b_local_legacy_hot_#{suffix}",
                 backend: FencedNodeRestartStore,
                 store_name: store_name,
                 start_store: false,
                 local_node: Kernel.node()
               ]
             ]}
        })

      entry = %JobRegistry.Entry{
        pipeline_id: legacy_run,
        run_id: legacy_run,
        graph_id: "legacy_local_graph",
        started_at: DateTime.add(now, -120, :second),
        completed_count: 1,
        total_nodes: 2,
        status: :running,
        source_node: Kernel.node(),
        owner_node: Kernel.node(),
        spawning_pid: dead_pid,
        last_heartbeat: DateTime.add(now, -120, :second),
        node_durations: %{}
      }

      assert :ok = Arbor.Persistence.BufferedStore.put(legacy_run, entry, name: jobs_store)

      on_exit(fn ->
        try do
          Arbor.Persistence.BufferedStore.delete(legacy_run, name: jobs_store)
        catch
          :exit, _ -> :ok
        end
      end)

      recovery_root = Path.join(System.tmp_dir!(), "l4b_local_legacy_root_#{suffix}")
      File.mkdir_p!(recovery_root)
      on_exit(fn -> File.rm_rf(recovery_root) end)

      {:ok, coord} =
        start_supervised(%{
          id: coord_name,
          start:
            {RecoveryCoordinator, :start_link,
             [
               [
                 name: coord_name,
                 enabled: true,
                 journal_opts: [server: journal_name],
                 recovery_root: recovery_root,
                 delay_ms: 60_000
               ]
             ]}
        })

      assert RecoveryCoordinator.status(coord_name).cross_node_atomic_recovery == true

      send(coord, :check_stale_heartbeats)
      _ = RecoveryCoordinator.status(coord_name)

      assert %JobRegistry.Entry{status: :abandoned} = JobRegistry.get(legacy_run)
      assert {:error, :not_found} = RunJournal.get_record(legacy_run, server: journal_name)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_journal_with_store(backend, suffix, tag, opts) do
    store_name = :"l4b_#{tag}_store_#{suffix}"
    journal_name = :"l4b_#{tag}_journal_#{suffix}"
    ets_table = :"l4b_#{tag}_hot_#{suffix}"
    local_node = Keyword.get(opts, :local_node, Kernel.node())

    {:ok, _} =
      start_supervised(%{
        id: store_name,
        start: {backend, :start_link, [[name: store_name]]}
      })

    {:ok, _} =
      start_supervised(%{
        id: journal_name,
        start:
          {RunJournal, :start_link,
           [
             [
               name: journal_name,
               ets_table: ets_table,
               backend: backend,
               store_name: store_name,
               start_store: false,
               local_node: local_node
             ]
           ]}
      })

    {journal_name, store_name}
  end
end
