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

  defmodule ThrowingStore do
    @moduledoc false

    def durability_class(_opts), do: throw({:backend_throw, :durability})
    def put(_key, _value, _opts), do: throw({:backend_throw, [1 | 2]})
    def get(_key, _opts), do: throw({:backend_throw, :get})
    def delete(_key, _opts), do: throw({:backend_throw, :delete})
    def list(_opts), do: throw({:backend_throw, :list})
  end

  defmodule UnexpectedGetShapeStore do
    @moduledoc false

    def durability_class(_opts), do: :process_lifetime
    def put(_key, _value, _opts), do: :ok
    # Intentionally not {:ok, value} | {:error, reason}.
    def get(_key, _opts), do: :unexpected_get_shape
    def delete(_key, _opts), do: :ok
    def list(_opts), do: {:ok, []}
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

    test "file write failure is surfaced and only this call's temp is cleaned", %{
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
    end

    test "security regression: file write failure cleanup never deletes foreign temp sentinel",
         %{tmp: tmp} do
      # Foreign sibling matching the old wildcard pattern checkpoint.json.*.tmp.
      # At f7a45dc7, cleanup_temp_globs/1 deleted this; after the fix only the
      # exact owned temp path is removed.
      foreign = Path.join(tmp, "checkpoint.json.foreign.sentinel.tmp")
      File.write!(foreign, "FOREIGN_SENTINEL_MUST_SURVIVE")

      # Force rename failure after this call creates its own exclusive temp:
      # checkpoint.json as a directory makes File.rename fail.
      File.mkdir_p!(Path.join(tmp, "checkpoint.json"))
      cp = sample_checkpoint("run_foreign_temp_security")

      assert {:error, {:file_write_failed, _}} =
               Checkpoint.persist(cp, tmp, store: nil)

      assert File.exists?(foreign)
      assert File.read!(foreign) == "FOREIGN_SENTINEL_MUST_SURVIVE"
    end

    test "security regression: checkpoint.json is created with private 0600 mode on Unix", %{
      tmp: tmp
    } do
      cp = sample_checkpoint("run_mode_0600")
      assert {:ok, _} = Checkpoint.persist(cp, tmp, store: nil)

      path = Path.join(tmp, "checkpoint.json")
      assert File.exists?(path)

      case :os.type() do
        {:unix, _} ->
          %{mode: mode} = File.stat!(path)
          assert :erlang.band(mode, 0o777) == 0o600

        _ ->
          :ok
      end
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

    test "invalid store option fails closed rather than weakening to file-only", %{tmp: tmp} do
      cp = sample_checkpoint("run_invalid_store")

      assert {:error, {:invalid_store_config, :store_not_atom_or_nil}} =
               Checkpoint.persist(cp, tmp, store: "not-a-module")

      assert {:error, {:invalid_store_config, :store_name_not_atom}} =
               Checkpoint.persist(cp, tmp, store: MemoryStore, store_name: "bad")

      assert {:error, {:invalid_store_config, :store_opts_not_keyword}} =
               Checkpoint.persist(cp, tmp,
                 store: MemoryStore,
                 store_name: :s,
                 store_opts: %{not: :keyword}
               )

      status = Checkpoint.durability_status(store: "bad")
      assert status.mode == :invalid_configuration
      assert status.durable == false
      assert status.last_error == {:invalid_store_config, :store_not_atom_or_nil}
    end

    test "malformed checkpoint run_id fails before writing a file", %{tmp: tmp} do
      cp = %{sample_checkpoint("run_valid") | run_id: :invalid}

      assert {:error, {:invalid_checkpoint, :run_id_not_binary_or_nil}} =
               Checkpoint.persist(cp, tmp, store: nil)

      refute File.exists?(Path.join(tmp, "checkpoint.json"))
    end

    test "backend throws and improper-list reasons stay bounded", %{tmp: tmp} do
      cp = sample_checkpoint("run_backend_throw")

      assert {:error, reason} =
               Checkpoint.persist(cp, tmp,
                 store: ThrowingStore,
                 store_name: :throwing_checkpoint_store
               )

      assert inspect(reason) =~ "backend_throw"
      assert byte_size(inspect(reason)) <= 512

      status =
        Checkpoint.durability_status(
          store: ThrowingStore,
          store_name: :throwing_checkpoint_store
        )

      assert status.healthy == false
      assert status.durable == false
      assert status.last_error != nil
    end

    test "replicate is not started when local writes fail", %{tmp: tmp, store_name: store_name} do
      :ok = MemoryStore.set_fail(store_name, :put)
      cp = sample_checkpoint("run_no_replicate_on_fail")

      assert {:error, {:store_put_failed, _}} =
               Checkpoint.persist(cp, tmp, store_opts(store_name, replicate: true))
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
      assert healthy.last_error == nil

      cp = sample_checkpoint("run_durable_ok")

      assert {:ok, receipt} =
               Checkpoint.persist(cp, tmp, store: MemoryStore, store_name: store_name)

      assert receipt.durable == true
      assert receipt.durability_class == :node_restart

      # Inject list outage → unhealthy → not durable, last_error bounded
      :ok = MemoryStore.set_fail(store_name, :list)
      unhealthy = Checkpoint.durability_status(store: MemoryStore, store_name: store_name)
      assert unhealthy.healthy == false
      assert unhealthy.durable == false
      assert unhealthy.durability_class == :node_restart
      assert unhealthy.last_error != nil
      refute match?(%{__exception__: true}, unhealthy.last_error)
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

    test "nonbinary run_id returns bounded invalid-option error", %{tmp: tmp} do
      cp = sample_checkpoint("run_bad_run_id")
      assert :ok = Checkpoint.write(cp, tmp, store: nil)

      assert {:error, {:invalid_option, :run_id_not_binary}} =
               Checkpoint.load(Path.join(tmp, "checkpoint.json"), run_id: :atom_run_id)
    end
  end

  describe "fetch_persisted/2" do
    test "roundtrip persist then fetch returns unwrapped payload map", %{
      tmp: tmp,
      store_name: store_name
    } do
      run_id = "run_fetch_roundtrip"
      cp = sample_checkpoint(run_id)
      assert {:ok, _} = Checkpoint.persist(cp, tmp, store_opts(store_name))

      assert {:ok, payload} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))
      assert is_map(payload)
      refute Map.has_key?(payload, :__struct__)
      refute match?(%PersistenceRecord{}, payload)
      assert payload["run_id"] == run_id
      assert payload["current_node"] == "n1"
      assert payload["graph_hash"] == "gh"
      assert is_map(payload["context_values"])
    end

    test "uses exact checkpoint:<run_id> key; bare run_id is not found", %{
      tmp: tmp,
      store_name: store_name
    } do
      run_id = "run_fetch_exact_key"
      cp = sample_checkpoint(run_id)
      assert {:ok, _} = Checkpoint.persist(cp, tmp, store_opts(store_name))

      data = MemoryStore.dump(store_name)
      assert Map.has_key?(data, "checkpoint:#{run_id}")
      refute Map.has_key?(data, run_id)

      # Value stored under the bare run_id must not be readable via fetch.
      :ok =
        MemoryStore.put(run_id, PersistenceRecord.new(run_id, %{"run_id" => run_id}),
          name: store_name
        )

      assert {:ok, _} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))

      # After deleting only the prefixed key, fetch must miss even if bare key remains.
      :ok = MemoryStore.delete("checkpoint:#{run_id}", name: store_name)
      assert {:error, :not_found} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))
      assert {:ok, _} = MemoryStore.get(run_id, name: store_name)
    end

    test "unwraps structured PersistenceRecord envelope", %{tmp: tmp, store_name: store_name} do
      run_id = "run_fetch_record"
      cp = sample_checkpoint(run_id)
      assert {:ok, _} = Checkpoint.persist(cp, tmp, store_opts(store_name))

      key = "checkpoint:#{run_id}"
      assert %PersistenceRecord{} = Map.fetch!(MemoryStore.dump(store_name), key)

      assert {:ok, payload} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))
      assert payload["run_id"] == run_id
      # Payload is the inner data map, not the Record wrapper fields.
      refute Map.has_key?(payload, "metadata")
      refute Map.has_key?(payload, "revision")
    end

    test "unwraps supported legacy raw-map payload", %{store_name: store_name} do
      run_id = "run_fetch_legacy"
      key = "checkpoint:#{run_id}"

      raw = %{
        "timestamp" => "2026-07-15T00:00:00Z",
        "run_id" => run_id,
        "current_node" => "n1",
        "completed_nodes" => [],
        "node_retries" => %{},
        "context_values" => %{"k" => "v"},
        "context_taint" => %{},
        "node_outcomes" => %{},
        "context_lineage" => %{},
        "content_hashes" => %{},
        "pending_intents" => %{},
        "execution_digests" => %{}
      }

      :ok = MemoryStore.put(key, raw, name: store_name)

      assert {:ok, payload} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))
      assert payload["run_id"] == run_id
      assert payload["context_values"]["k"] == "v"
    end

    test "unwraps serialized Record-shaped map envelope", %{store_name: store_name} do
      run_id = "run_fetch_serialized_envelope"
      key = "checkpoint:#{run_id}"

      envelope = %{
        "key" => key,
        "id" => "rec_test",
        "revision" => 1,
        "data" => %{
          "timestamp" => "2026-07-15T00:00:00Z",
          "run_id" => run_id,
          "current_node" => "n2",
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
      }

      :ok = MemoryStore.put(key, envelope, name: store_name)

      assert {:ok, payload} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))
      assert payload["run_id"] == run_id
      assert payload["current_node"] == "n2"
      refute Map.has_key?(payload, "revision")
    end

    test "missing key returns :not_found", %{store_name: store_name} do
      assert {:error, :not_found} =
               Checkpoint.fetch_persisted("run_fetch_missing", store_opts(store_name))
    end

    test "wrong Record key fails closed", %{store_name: store_name} do
      run_id = "run_fetch_wrong_key"
      key = "checkpoint:#{run_id}"

      mismatched =
        PersistenceRecord.new("checkpoint:other_run", %{
          "run_id" => run_id,
          "current_node" => "n1",
          "timestamp" => "2026-07-15T00:00:00Z"
        })

      :ok = MemoryStore.put(key, mismatched, name: store_name)

      assert {:error, :checkpoint_key_mismatch} =
               Checkpoint.fetch_persisted(run_id, store_opts(store_name))
    end

    test "wrong serialized envelope key fails closed", %{store_name: store_name} do
      run_id = "run_fetch_wrong_envelope_key"
      key = "checkpoint:#{run_id}"

      envelope = %{
        "key" => "checkpoint:someone_else",
        "id" => "rec_x",
        "data" => %{"run_id" => run_id, "current_node" => "n1"}
      }

      :ok = MemoryStore.put(key, envelope, name: store_name)

      assert {:error, :checkpoint_key_mismatch} =
               Checkpoint.fetch_persisted(run_id, store_opts(store_name))
    end

    test "payload under correct key but foreign run_id fails closed", %{store_name: store_name} do
      requested = "run_fetch_requested"
      foreign = "run_fetch_foreign"
      key = "checkpoint:#{requested}"

      foreign_payload = %{
        "timestamp" => "2026-07-15T00:00:00Z",
        "run_id" => foreign,
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
        MemoryStore.put(key, PersistenceRecord.new(key, foreign_payload), name: store_name)

      assert {:error, :checkpoint_run_id_mismatch} =
               Checkpoint.fetch_persisted(requested, store_opts(store_name))
    end

    test "missing or nonbinary payload run_id fails closed", %{store_name: store_name} do
      requested = "run_fetch_missing_payload_id"
      key = "checkpoint:#{requested}"

      without_run_id = %{
        "timestamp" => "2026-07-15T00:00:00Z",
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
        MemoryStore.put(key, PersistenceRecord.new(key, without_run_id), name: store_name)

      assert {:error, :checkpoint_run_id_mismatch} =
               Checkpoint.fetch_persisted(requested, store_opts(store_name))

      nonbinary = Map.put(without_run_id, "run_id", :atom_run_id)

      :ok =
        MemoryStore.put(key, PersistenceRecord.new(key, nonbinary), name: store_name)

      assert {:error, :checkpoint_run_id_mismatch} =
               Checkpoint.fetch_persisted(requested, store_opts(store_name))
    end

    test "HMAC-valid foreign-run payload under requested key still fails closed", %{
      store_name: store_name
    } do
      # HMAC verifies integrity using AAD derived from the *payload* fields.
      # A correctly signed foreign-run payload stored under the requested key
      # must still be rejected by the payload run_id binding check.
      requested = "run_fetch_hmac_requested"
      foreign = "run_fetch_hmac_foreign"
      secret = "test_secret_32_bytes_xxxxxxxxxxxx"
      key = "checkpoint:#{requested}"

      foreign_payload = %{
        "timestamp" => "2026-07-15T00:00:00Z",
        "run_id" => foreign,
        "graph_hash" => "gh_foreign",
        "current_node" => "n_foreign",
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

      signed =
        Checkpoint.sign(foreign_payload, secret,
          run_id: foreign,
          current_node: "n_foreign",
          graph_hash: "gh_foreign"
        )

      :ok =
        MemoryStore.put(key, PersistenceRecord.new(key, signed), name: store_name)

      assert {:error, :checkpoint_run_id_mismatch} =
               Checkpoint.fetch_persisted(requested, store_opts(store_name, hmac_secret: secret))
    end

    test "corrupt non-map payload is rejected", %{store_name: store_name} do
      run_id = "run_fetch_corrupt"
      key = "checkpoint:#{run_id}"
      :ok = MemoryStore.put(key, "not-a-map-payload", name: store_name)

      assert {:error, :invalid_checkpoint_payload} =
               Checkpoint.fetch_persisted(run_id, store_opts(store_name))
    end

    test "Record with non-map data is rejected", %{store_name: store_name} do
      run_id = "run_fetch_record_corrupt"
      key = "checkpoint:#{run_id}"
      # Bypass Record.new/2 which expects map data by building a bare struct shape
      # the store may return after corruption.
      corrupt = %{__struct__: PersistenceRecord, key: key, data: [1, 2, 3], metadata: %{}}
      :ok = MemoryStore.put(key, corrupt, name: store_name)

      assert {:error, reason} = Checkpoint.fetch_persisted(run_id, store_opts(store_name))
      assert reason in [:invalid_checkpoint_payload, :checkpoint_key_mismatch]
    end

    test "store: nil yields typed store_not_configured, never file fallback", %{tmp: tmp} do
      run_id = "run_fetch_file_only"
      cp = sample_checkpoint(run_id)
      assert :ok = Checkpoint.write(cp, tmp, store: nil)
      assert File.exists?(Path.join(tmp, "checkpoint.json"))

      assert {:error, :store_not_configured} =
               Checkpoint.fetch_persisted(run_id, store: nil)
    end

    test "invalid store config fails closed", %{store_name: store_name} do
      assert {:error, {:invalid_store_config, :store_not_atom_or_nil}} =
               Checkpoint.fetch_persisted("run_x", store: "not-a-module")

      assert {:error, {:invalid_store_config, :store_name_not_atom}} =
               Checkpoint.fetch_persisted("run_x", store: MemoryStore, store_name: "bad")

      assert {:error, {:invalid_store_config, :store_opts_not_keyword}} =
               Checkpoint.fetch_persisted("run_x",
                 store: MemoryStore,
                 store_name: store_name,
                 store_opts: %{not: :keyword}
               )
    end

    test "nonbinary run_id fails closed" do
      assert {:error, {:invalid_option, :run_id_not_binary}} =
               Checkpoint.fetch_persisted(:atom_run_id, store: nil)
    end

    test "backend get outage is surfaced as store_unavailable", %{store_name: store_name} do
      :ok = MemoryStore.set_fail(store_name, :get)

      assert {:error, {:store_unavailable, _}} =
               Checkpoint.fetch_persisted("run_fetch_outage", store_opts(store_name))
    end

    test "backend throw is bounded as store_unavailable" do
      assert {:error, {:store_unavailable, reason}} =
               Checkpoint.fetch_persisted("run_fetch_throw",
                 store: ThrowingStore,
                 store_name: :throwing_fetch_store
               )

      assert inspect(reason) =~ "backend_throw"
      assert byte_size(inspect(reason)) <= 512
    end

    test "unexpected backend get shape is store_unavailable" do
      assert {:error, {:store_unavailable, reason}} =
               Checkpoint.fetch_persisted("run_fetch_bad_shape",
                 store: UnexpectedGetShapeStore,
                 store_name: :unexpected_get_shape_store
               )

      assert match?({:unexpected_get_result, _}, reason) or
               is_binary(reason) or is_atom(reason) or is_tuple(reason)

      refute match?(%{__exception__: true}, reason)
    end

    test "does not expose arbitrary key reads", %{store_name: store_name} do
      # Foreign key under a different prefix must remain unreachable.
      :ok =
        MemoryStore.put(
          "secret:run_foreign",
          PersistenceRecord.new("secret:run_foreign", %{"secret" => true}),
          name: store_name
        )

      assert {:error, :not_found} =
               Checkpoint.fetch_persisted("run_foreign", store_opts(store_name))

      assert {:ok, _} = MemoryStore.get("secret:run_foreign", name: store_name)
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

    test "cleanup_older_than safely skips malformed nonbinary keys", %{store_name: store_name} do
      # Inject a non-binary key alongside a valid old checkpoint key.
      # MemoryStore list returns Map.keys; put an atom key via GenServer state.
      :ok =
        GenServer.call(
          store_name,
          {:put, :not_a_binary_key, %{"timestamp" => "2000-01-01T00:00:00Z"}}
        )

      old_payload = %{
        "timestamp" => "2000-01-01T00:00:00Z",
        "run_id" => "run_skip_malformed",
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

      key = "checkpoint:run_skip_malformed"
      :ok = MemoryStore.put(key, PersistenceRecord.new(key, old_payload), name: store_name)

      assert {:ok, count} = Checkpoint.cleanup_older_than(60, store_opts(store_name))
      assert count >= 1
      assert {:error, :not_found} = MemoryStore.get(key, name: store_name)
    end
  end
end
