defmodule Arbor.Orchestrator.Engine.CheckpointHonestPersistenceTest do
  @moduledoc """
  Focused honesty tests for Checkpoint.persist/3, durability_status/1,
  load outage surface, Record envelopes, and cleanup error propagation.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Orchestrator.Engine.Context

  defmodule MemoryStore do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)

      %{
        id: name,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def durability_class(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, :durability_class)
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      class = Keyword.get(opts, :class, :process_lifetime)
      GenServer.start_link(__MODULE__, %{class: class, data: %{}, fail: nil}, name: name)
    end

    def put(key, value, opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:put, key, value})
    end

    def get(key, opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:get, key})
    end

    def delete(key, opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:delete, key})
    end

    def list(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, :list)
    end

    def set_fail(name, fail), do: GenServer.call(name, {:set_fail, fail})
    def set_class(name, class), do: GenServer.call(name, {:set_class, class})
    def dump(name), do: GenServer.call(name, :dump)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:durability_class, _from, state), do: {:reply, state.class, state}

    def handle_call({:set_class, class}, _from, state),
      do: {:reply, :ok, %{state | class: class}}

    def handle_call({:set_fail, fail}, _from, state),
      do: {:reply, :ok, %{state | fail: fail}}

    def handle_call(:dump, _from, state), do: {:reply, state.data, state}

    def handle_call({:put, _key, _value}, _from, %{fail: :put} = state) do
      {:reply, {:error, :injected_put_failure}, state}
    end

    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
    end

    def handle_call({:get, _key}, _from, %{fail: :get} = state) do
      {:reply, {:error, :injected_get_outage}, state}
    end

    def handle_call({:get, key}, _from, state) do
      case Map.fetch(state.data, key) do
        {:ok, v} -> {:reply, {:ok, v}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, _key}, _from, %{fail: :delete} = state) do
      {:reply, {:error, :injected_delete_failure}, state}
    end

    def handle_call({:delete, key}, _from, state) do
      {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
    end

    def handle_call(:list, _from, %{fail: :list} = state) do
      {:reply, {:error, :injected_list_failure}, state}
    end

    def handle_call(:list, _from, state) do
      {:reply, {:ok, Map.keys(state.data)}, state}
    end
  end

  defmodule ModuleOnlyNodeRestartStore do
    @moduledoc false
    @table :checkpoint_honest_module_only_store

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:named_table, :public, :set])

        _ ->
          @table
      end
    end

    def durability_class(_opts), do: :node_restart

    def put(key, value, _opts) do
      ensure_table!()
      true = :ets.insert(@table, {key, value})
      :ok
    end

    def get(key, _opts) do
      ensure_table!()

      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end
    end

    def delete(key, _opts) do
      ensure_table!()
      true = :ets.delete(@table, key)
      :ok
    end

    def list(_opts) do
      ensure_table!()
      {:ok, :ets.foldl(fn {k, _}, acc -> [k | acc] end, [], @table)}
    end

    def clear! do
      ensure_table!()
      true = :ets.delete_all_objects(@table)
      :ok
    end
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "checkpoint_honest_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"checkpoint_honest_store_#{suffix}"

    {:ok, _pid} =
      start_supervised({MemoryStore, name: store_name, class: :process_lifetime})

    %{tmp: tmp, store_name: store_name}
  end

  defp sample_checkpoint(run_id) do
    ctx = Context.new(%{"k" => "v"})
    Checkpoint.from_state("n1", ["start"], %{}, ctx, %{}, run_id: run_id, graph_hash: "gh")
  end

  defp store_opts(store_name, extra \\ []) do
    Keyword.merge(
      [store: MemoryStore, store_name: store_name],
      extra
    )
  end

  describe "persist/3 and write/3 honesty" do
    test "persist returns bounded durable:false receipt for process-lifetime store", %{
      tmp: tmp,
      store_name: store_name
    } do
      cp = sample_checkpoint("run_persist_ok")

      assert {:ok, receipt} = Checkpoint.persist(cp, tmp, store_opts(store_name))
      assert receipt.store == :ok
      assert receipt.file == :ok
      assert receipt.durable == false
      assert receipt.durability_class == :process_lifetime
      assert receipt.peer_replication == :not_requested
      assert File.exists?(Path.join(tmp, "checkpoint.json"))
    end

    test "write/3 returns :ok only when persist succeeds", %{tmp: tmp, store_name: store_name} do
      cp = sample_checkpoint("run_write_ok")
      assert :ok = Checkpoint.write(cp, tmp, store_opts(store_name))
    end

    test "store put failure is surfaced and not swallowed into :ok", %{
      tmp: tmp,
      store_name: store_name
    } do
      :ok = MemoryStore.set_fail(store_name, :put)
      cp = sample_checkpoint("run_put_fail")

      assert {:error, reason} = Checkpoint.persist(cp, tmp, store_opts(store_name))
      assert match?({:store_put_failed, _}, reason)
      assert {:error, _} = Checkpoint.write(cp, tmp, store_opts(store_name))
      # public reason is bounded — no exception struct
      refute match?(%{__exception__: true}, reason)
      refute match?({:store_put_failed, %{__exception__: true}}, reason)
    end

    test "file write failure is surfaced and temp artifacts are cleaned", %{
      store_name: store_name
    } do
      # Use a path whose parent is a file so mkdir_p/write cannot succeed cleanly.
      parent =
        Path.join(
          System.tmp_dir!(),
          "checkpoint_file_fail_#{:erlang.unique_integer([:positive])}"
        )

      File.write!(parent, "not-a-dir")
      on_exit(fn -> File.rm_rf(parent) end)

      bad_root = Path.join(parent, "nested")
      cp = sample_checkpoint("run_file_fail")

      assert {:error, {:file_write_failed, _}} =
               Checkpoint.persist(cp, bad_root, store_opts(store_name))

      # No leftover temp files under the parent (or nested, if partially created)
      leftovers =
        Path.wildcard(Path.join(parent, "**/*checkpoint.json*.tmp")) ++
          Path.wildcard(Path.join(parent, "*checkpoint.json*.tmp"))

      assert leftovers == []
    end

    test "file-only mode skips store and reports non-durable", %{tmp: tmp} do
      cp = sample_checkpoint("run_file_only")

      assert {:ok, receipt} = Checkpoint.persist(cp, tmp, store: nil)
      assert receipt.store == :skipped
      assert receipt.file == :ok
      assert receipt.durable == false

      status = Checkpoint.durability_status(store: nil)
      assert status.durable == false
      assert status.durability_class == :volatile
      assert status.mode == :file_only
    end
  end

  describe "durability_status/1 honesty" do
    test "default BufferedStore / process-lifetime is non-durable", %{store_name: store_name} do
      status = Checkpoint.durability_status(store_opts(store_name))
      assert status.durable == false
      assert status.durability_class == :process_lifetime
      assert status.peer_replication_durable == false
    end

    test "default durability_status without injection is non-durable" do
      status = Checkpoint.durability_status()
      assert status.durable == false
      assert status.durability_class in [:process_lifetime, :volatile]
      assert status.peer_replication_durable == false
    end

    test "caller option cannot elevate backend durability", %{store_name: store_name} do
      status =
        Checkpoint.durability_status(store_opts(store_name, durability_class: :node_restart))

      assert status.durability_class == :process_lifetime
      assert status.durable == false
    end

    test "durable fake backend is durable only when healthy", %{
      tmp: tmp
    } do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"checkpoint_durable_store_#{suffix}"
      {:ok, _} = start_supervised({MemoryStore, name: store_name, class: :node_restart})

      healthy = Checkpoint.durability_status(store: MemoryStore, store_name: store_name)
      assert healthy.durability_class == :node_restart
      assert healthy.durable == true
      assert healthy.healthy == true

      cp = sample_checkpoint("run_durable_ok")

      assert {:ok, receipt} =
               Checkpoint.persist(cp, tmp, store: MemoryStore, store_name: store_name)

      assert receipt.durable == true
      assert receipt.durability_class == :node_restart

      # Inject list outage → unhealthy → not durable
      :ok = MemoryStore.set_fail(store_name, :list)
      unhealthy = Checkpoint.durability_status(store: MemoryStore, store_name: store_name)
      assert unhealthy.healthy == false
      assert unhealthy.durable == false
      assert unhealthy.durability_class == :node_restart
    end

    test "ceiling can lower but not raise application_restart capability" do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"checkpoint_app_restart_#{suffix}"
      {:ok, _} = start_supervised({MemoryStore, name: store_name, class: :application_restart})

      assert Checkpoint.durability_status(store: MemoryStore, store_name: store_name).durable ==
               true

      lowered =
        Checkpoint.durability_status(
          store: MemoryStore,
          store_name: store_name,
          durability_class: :process_lifetime
        )

      assert lowered.durability_class == :process_lifetime
      assert lowered.durable == false
    end
  end

  describe "Record envelope for Postgres-shaped backends" do
    test "persist stores a Persistence.Record envelope", %{tmp: tmp, store_name: store_name} do
      cp = sample_checkpoint("run_record_envelope")
      assert {:ok, _} = Checkpoint.persist(cp, tmp, store_opts(store_name))

      key = "checkpoint:run_record_envelope"
      data = MemoryStore.dump(store_name)
      assert %PersistenceRecord{} = record = Map.fetch!(data, key)
      assert record.key == key
      assert is_map(record.data)

      assert record.data["run_id"] == "run_record_envelope" or
               record.data[:run_id] == "run_record_envelope"

      assert record.metadata["type"] == "engine_checkpoint"
    end

    test "load accepts Record envelope and legacy raw map", %{tmp: tmp, store_name: store_name} do
      cp = sample_checkpoint("run_record_load")
      assert {:ok, _} = Checkpoint.persist(cp, tmp, store_opts(store_name))

      assert {:ok, loaded} =
               Checkpoint.load(Path.join(tmp, "checkpoint.json"),
                 run_id: "run_record_load",
                 store: MemoryStore,
                 store_name: store_name
               )

      assert loaded.run_id == "run_record_load"

      # Legacy raw-map payload compatibility
      raw = %{
        "timestamp" => "2026-07-15T00:00:00Z",
        "run_id" => "run_legacy_raw",
        "current_node" => "n1",
        "completed_nodes" => [],
        "node_retries" => %{},
        "context_values" => %{},
        "context_taint" => %{},
        "node_outcomes" => %{},
        "context_lineage" => %{},
        "content_hashes" => %{},
        "pending_intents" => %{},
        "execution_digests" => %{}
      }

      :ok =
        MemoryStore.put("checkpoint:run_legacy_raw", raw, name: store_name)

      assert {:ok, legacy} =
               Checkpoint.load(Path.join(tmp, "checkpoint.json"),
                 run_id: "run_legacy_raw",
                 store: MemoryStore,
                 store_name: store_name
               )

      assert legacy.run_id == "run_legacy_raw"
    end

    test "module-only node_restart store receives Record and is durable when healthy", %{
      tmp: tmp
    } do
      ModuleOnlyNodeRestartStore.clear!()
      store_name = :checkpoint_module_only_nr

      cp = sample_checkpoint("run_module_only")

      assert {:ok, receipt} =
               Checkpoint.persist(cp, tmp,
                 store: ModuleOnlyNodeRestartStore,
                 store_name: store_name
               )

      assert receipt.durable == true
      assert receipt.durability_class == :node_restart

      assert {:ok, %PersistenceRecord{}} =
               ModuleOnlyNodeRestartStore.get("checkpoint:run_module_only", name: store_name)
    end
  end

  describe "load outage vs not_found" do
    test "configured backend outage is not hidden by a valid fallback file", %{
      tmp: tmp,
      store_name: store_name
    } do
      cp = sample_checkpoint("run_outage_fallback")
      # Write a valid local file first (file-only)
      assert :ok = Checkpoint.write(cp, tmp, store: nil)
      assert File.exists?(Path.join(tmp, "checkpoint.json"))

      :ok = MemoryStore.set_fail(store_name, :get)

      assert {:error, {:store_unavailable, _}} =
               Checkpoint.load(Path.join(tmp, "checkpoint.json"),
                 run_id: "run_outage_fallback",
                 store: MemoryStore,
                 store_name: store_name
               )
    end

    test "genuine :not_found falls back to file", %{tmp: tmp, store_name: store_name} do
      cp = sample_checkpoint("run_not_found_fallback")
      assert :ok = Checkpoint.write(cp, tmp, store: nil)

      assert {:ok, loaded} =
               Checkpoint.load(Path.join(tmp, "checkpoint.json"),
                 run_id: "run_not_found_fallback",
                 store: MemoryStore,
                 store_name: store_name
               )

      assert loaded.run_id == "run_not_found_fallback"
    end
  end

  describe "cleanup error surface" do
    test "cleanup is idempotent for missing keys", %{store_name: store_name} do
      assert :ok = Checkpoint.cleanup("missing_run", store_opts(store_name))
    end

    test "cleanup surfaces store delete failures", %{store_name: store_name} do
      :ok = MemoryStore.set_fail(store_name, :delete)

      assert {:error, reason} =
               Checkpoint.cleanup("any_run", store_opts(store_name))

      assert match?({:store_delete_failed, _}, reason)
    end

    test "cleanup_older_than surfaces list failures", %{store_name: store_name} do
      :ok = MemoryStore.set_fail(store_name, :list)

      assert {:error, reason} =
               Checkpoint.cleanup_older_than(60, store_opts(store_name))

      assert match?({:store_list_failed, _}, reason)
    end

    test "cleanup_older_than deletes old records and counts them", %{
      store_name: store_name
    } do
      # Force an old timestamp by writing a Record with an old payload timestamp
      old_payload = %{
        "timestamp" => "2000-01-01T00:00:00Z",
        "run_id" => "run_old_cleanup",
        "current_node" => "n1",
        "completed_nodes" => [],
        "node_retries" => %{},
        "context_values" => %{},
        "context_taint" => %{},
        "node_outcomes" => %{},
        "context_lineage" => %{},
        "content_hashes" => %{},
        "pending_intents" => %{},
        "execution_digests" => %{}
      }

      key = "checkpoint:run_old_cleanup"
      record = PersistenceRecord.new(key, old_payload)
      :ok = MemoryStore.put(key, record, name: store_name)

      assert {:ok, count} = Checkpoint.cleanup_older_than(60, store_opts(store_name))
      assert count >= 1

      assert {:error, :not_found} = MemoryStore.get(key, name: store_name)
    end
  end
end
