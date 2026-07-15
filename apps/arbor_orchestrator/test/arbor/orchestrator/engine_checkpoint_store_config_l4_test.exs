defmodule Arbor.Orchestrator.EngineCheckpointStoreConfigL4Test do
  @moduledoc """
  L4C2a: code-owned Engine checkpoint-store configuration.

  Proves Config defaults preserve historical BufferedStore semantics, Engine
  threads Config authority into Checkpoint persist/load/cleanup, callers cannot
  spoof store targets, malformed config fails closed, and store:nil is file-only.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Application, as: OrchestratorApp
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Persistence.BufferedStore

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

      GenServer.start_link(__MODULE__, %{class: class, data: %{}, puts: 0, deletes: 0},
        name: name
      )
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

    def dump(name), do: GenServer.call(name, :dump)
    def stats(name), do: GenServer.call(name, :stats)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:durability_class, _from, state), do: {:reply, state.class, state}
    def handle_call(:dump, _from, state), do: {:reply, state.data, state}

    def handle_call(:stats, _from, state),
      do: {:reply, %{puts: state.puts, deletes: state.deletes, keys: Map.keys(state.data)}, state}

    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, %{state | data: Map.put(state.data, key, value), puts: state.puts + 1}}
    end

    def handle_call({:get, key}, _from, state) do
      case Map.fetch(state.data, key) do
        {:ok, v} -> {:reply, {:ok, v}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, key}, _from, state) do
      {:reply, :ok, %{state | data: Map.delete(state.data, key), deletes: state.deletes + 1}}
    end

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}
  end

  defmodule SpoofStore do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{data: %{}, puts: 0}, name: name)
    end

    def durability_class(_opts), do: :process_lifetime

    def put(key, value, opts) do
      GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    end

    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def stats(name), do: GenServer.call(name, :stats)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, %{state | data: Map.put(state.data, key, value), puts: state.puts + 1}}
    end

    def handle_call({:get, key}, _from, state) do
      case Map.fetch(state.data, key) do
        {:ok, v} -> {:reply, {:ok, v}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, key}, _from, state) do
      {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
    end

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}
    def handle_call(:stats, _from, state), do: {:reply, %{puts: state.puts}, state}
  end

  defmodule SideProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:ckpt_cfg_probe, node.id, opts[:run_id], opts[:execution_id]})
      end

      %Outcome{status: :success, context_updates: %{"probe" => node.id}}
    end
  end

  defmodule BlockProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:ckpt_cfg_block, node.id, opts[:run_id]})
      end

      receive do
        :never -> :ok
      after
        60_000 -> :ok
      end

      %Outcome{status: :success}
    end
  end

  setup do
    saved_env = Application.get_env(:arbor_orchestrator, :engine_checkpoints, :__unset__)

    on_exit(fn ->
      case saved_env do
        :__unset__ -> Application.delete_env(:arbor_orchestrator, :engine_checkpoints)
        value -> Application.put_env(:arbor_orchestrator, :engine_checkpoints, value)
      end
    end)

    saved_handlers = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    :ok = Registry.register("ckpt_cfg_side", SideProbe)
    :ok = Registry.register("ckpt_cfg_block", BlockProbe)
    on_exit(fn -> Registry.restore_custom_handlers(saved_handlers) end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Config defaults + validation
  # ---------------------------------------------------------------------------

  describe "Config.engine_checkpoints/0" do
    test "default preserves BufferedStore name/collection and process-lifetime honesty" do
      Application.delete_env(:arbor_orchestrator, :engine_checkpoints)

      assert {:ok, opts} = Config.fetch_engine_checkpoints()
      assert opts[:store] == BufferedStore
      assert opts[:store_name] == :arbor_orchestrator_checkpoints
      assert opts[:store_opts] == []
      assert opts[:start_store] == true
      assert opts[:store_child_opts][:collection] == "orchestrator_checkpoints"
      # store_name is pinned into store_child_opts[:name] during validation.
      assert opts[:store_child_opts][:name] == :arbor_orchestrator_checkpoints
      assert opts[:durability_class] == :process_lifetime

      assert {:ok, store_opts} = Config.fetch_engine_checkpoint_store_opts()
      assert store_opts[:store] == BufferedStore
      assert store_opts[:store_name] == :arbor_orchestrator_checkpoints
      assert store_opts[:store_opts] == []
      assert store_opts[:durability_class] == :process_lifetime
      refute Keyword.has_key?(store_opts, :start_store)
      refute Keyword.has_key?(store_opts, :store_child_opts)
    end

    test "store:nil is accepted as explicit file-only" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints, store: nil)

      assert {:ok, opts} = Config.fetch_engine_checkpoints()
      assert opts[:store] == nil

      assert {:ok, store_opts} = Config.fetch_engine_checkpoint_store_opts()
      assert store_opts[:store] == nil
    end

    test "conflicting store_child_opts[:name] fails closed" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store_name: :canonical_checkpoint_store,
        store_child_opts: [name: :other_name, collection: "x"]
      )

      assert {:error, {:store_child_name_conflict, :other_name, :canonical_checkpoint_store}} =
               Config.fetch_engine_checkpoints()
    end

    test "matching store_child_opts[:name] is accepted and re-pinned to store_name" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store_name: :canonical_checkpoint_store,
        store_child_opts: [name: :canonical_checkpoint_store, collection: "x"]
      )

      assert {:ok, opts} = Config.fetch_engine_checkpoints()
      assert opts[:store_name] == :canonical_checkpoint_store
      assert opts[:store_child_opts][:name] == :canonical_checkpoint_store
      assert opts[:store_child_opts][:collection] == "x"
    end

    test "malformed config fails closed" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints, "not-a-keyword")
      assert {:error, :not_keyword} = Config.fetch_engine_checkpoints()

      Application.put_env(:arbor_orchestrator, :engine_checkpoints, store: "BufferedStore")
      assert {:error, :store_not_atom_or_nil} = Config.fetch_engine_checkpoints()

      Application.put_env(:arbor_orchestrator, :engine_checkpoints, store_name: "bad")
      assert {:error, :store_name_not_atom} = Config.fetch_engine_checkpoints()

      Application.put_env(:arbor_orchestrator, :engine_checkpoints, store_opts: %{a: 1})
      assert {:error, :store_opts_not_keyword} = Config.fetch_engine_checkpoints()

      Application.put_env(:arbor_orchestrator, :engine_checkpoints, start_store: "yes")
      assert {:error, :start_store_not_boolean} = Config.fetch_engine_checkpoints()

      Application.put_env(:arbor_orchestrator, :engine_checkpoints, durability_class: :warp_drive)

      assert {:error, :invalid_durability_class} = Config.fetch_engine_checkpoints()

      Application.put_env(:arbor_orchestrator, :engine_checkpoints, unknown_key: true)
      assert {:error, {:unknown_keys, [:unknown_key]}} = Config.fetch_engine_checkpoints()

      assert_raise ArgumentError, fn -> Config.engine_checkpoints() end
    end
  end

  describe "Application checkpoint child derivation" do
    test "invalid env fails closed before supervision (same branch as Application.start)" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints, store: "nope")

      # Application.start/2 is already running under test; exercise the same
      # validation branch the start callback uses without restarting the live app.
      assert {:error, :store_not_atom_or_nil} = Config.fetch_engine_checkpoints()

      assert match?(
               {:error, {:invalid_engine_checkpoints, :store_not_atom_or_nil}},
               case Config.fetch_engine_checkpoints() do
                 {:error, reason} -> {:error, {:invalid_engine_checkpoints, reason}}
                 {:ok, _} -> :ok
               end
             )
    end

    test "default BufferedStore is startable and names the child after store_name" do
      Application.delete_env(:arbor_orchestrator, :engine_checkpoints)
      assert {:ok, opts} = Config.fetch_engine_checkpoints()

      assert {:ok, [{BufferedStore, child_opts}]} =
               OrchestratorApp.checkpoint_store_child_spec(opts)

      assert child_opts[:name] == :arbor_orchestrator_checkpoints
      assert child_opts[:collection] == "orchestrator_checkpoints"
    end

    test "store:nil and start_store:false yield no supervised child" do
      assert {:ok, []} =
               OrchestratorApp.checkpoint_store_child_spec(
                 store: nil,
                 store_name: :unused,
                 start_store: true,
                 store_child_opts: []
               )

      assert {:ok, []} =
               OrchestratorApp.checkpoint_store_child_spec(
                 store: MemoryStore,
                 store_name: :external_store,
                 start_store: false,
                 store_child_opts: [name: :spoof]
               )
    end

    test "start_store:true fails closed when module has no start_link/1" do
      # String is a loaded atom module that does not export start_link/1.
      assert {:error, {:checkpoint_store_unstartable, :missing_start_link}} =
               OrchestratorApp.checkpoint_store_child_spec(
                 store: String,
                 store_name: :nope,
                 start_store: true,
                 store_child_opts: []
               )
    end

    test "start_store:true fails closed when module cannot be loaded" do
      missing = :"Elixir.Arbor.NonexistentCheckpointStore#{System.unique_integer([:positive])}"

      assert {:error, {:checkpoint_store_unstartable, {:module_not_loadable, _}}} =
               OrchestratorApp.checkpoint_store_child_spec(
                 store: missing,
                 store_name: :nope,
                 start_store: true,
                 store_child_opts: []
               )
    end

    test "store_name overwrites conflicting store_child_opts[:name] in child spec" do
      # Config rejects conflicts; the pure Application helper still enforces
      # store_name as the registration name when handed raw opts.
      assert {:ok, [{MemoryStore, child_opts}]} =
               OrchestratorApp.checkpoint_store_child_spec(
                 store: MemoryStore,
                 store_name: :canonical_name,
                 start_store: true,
                 store_child_opts: [name: :attacker_name, collection: "x"]
               )

      assert child_opts[:name] == :canonical_name
      refute child_opts[:name] == :attacker_name
      assert child_opts[:collection] == "x"
    end
  end

  # ---------------------------------------------------------------------------
  # Engine path: real persist / load / cleanup via Config
  # ---------------------------------------------------------------------------

  describe "Engine threads Config checkpoint store authority" do
    test "configured store receives persist and cleanup through Engine.run" do
      store_name = unique_store_name("ckpt_cfg_ok")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})

      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: MemoryStore,
        store_name: store_name,
        start_store: false,
        store_child_opts: []
      )

      logs_root = tmp_logs("ckpt_cfg_ok")
      run_id = "ckpt_cfg_ok_#{System.unique_integer([:positive, :monotonic])}"
      parent = self()

      assert {:ok, result} =
               Engine.run(parse!(side_dot()),
                 run_id: run_id,
                 logs_root: logs_root,
                 parent: parent,
                 resumable: true
               )

      assert_receive {:ckpt_cfg_probe, "task", ^run_id, _}, 2_000
      assert result.run_id == run_id

      # Successful completion cleans the configured store entry.
      stats = MemoryStore.stats(store_name)
      assert stats.puts >= 1
      assert stats.deletes >= 1
      refute Map.has_key?(MemoryStore.dump(store_name), checkpoint_key(run_id))
    end

    test "configured store is used for mid-run checkpoint and resume load" do
      store_name = unique_store_name("ckpt_cfg_resume")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})

      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: MemoryStore,
        store_name: store_name,
        start_store: false
      )

      logs_root = tmp_logs("ckpt_cfg_resume")
      run_id = "ckpt_cfg_resume_#{System.unique_integer([:positive, :monotonic])}"
      parent = self()
      identity = :crypto.strong_rand_bytes(32)

      {engine_pid, mon} =
        spawn_monitor(fn ->
          Engine.run(parse!(block_dot()),
            run_id: run_id,
            logs_root: logs_root,
            parent: parent,
            identity_private_key: identity,
            resumable: true
          )
        end)

      assert_receive {:ckpt_cfg_block, "task", ^run_id}, 5_000

      # Start-node checkpoint must already be in the configured store.
      dump = MemoryStore.dump(store_name)
      assert Map.has_key?(dump, checkpoint_key(run_id))
      assert MemoryStore.stats(store_name).puts >= 1

      Process.exit(engine_pid, :kill)
      assert_receive {:DOWN, ^mon, :process, ^engine_pid, :killed}, 2_000

      # Prove load uses the configured store: remove the compatibility file so
      # Checkpoint.load cannot fall back to disk.
      File.rm(Path.join(logs_root, "checkpoint.json"))

      assert {:ok, cp} =
               Arbor.Orchestrator.Engine.Checkpoint.load(
                 Path.join(logs_root, "checkpoint.json"),
                 Config.engine_checkpoint_store_opts()
                 |> Keyword.put(:run_id, run_id)
                 |> Keyword.put(
                   :hmac_secret,
                   Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
                 )
               )

      assert cp.run_id == run_id
      assert cp.current_node == "start"
      assert "start" in cp.completed_nodes
    end

    test "caller-supplied spoofed store target cannot override Config authority" do
      real_name = unique_store_name("ckpt_cfg_real")
      spoof_name = unique_store_name("ckpt_cfg_spoof")
      {:ok, _} = start_supervised({MemoryStore, name: real_name})
      {:ok, _} = start_supervised({SpoofStore, name: spoof_name})

      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: MemoryStore,
        store_name: real_name,
        start_store: false
      )

      logs_root = tmp_logs("ckpt_cfg_spoof")
      run_id = "ckpt_cfg_spoof_#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _} =
               Engine.run(parse!(side_dot()),
                 run_id: run_id,
                 logs_root: logs_root,
                 parent: self(),
                 resumable: true,
                 # Spoof attempts — must be ignored at Engine boundary.
                 store: SpoofStore,
                 store_name: spoof_name,
                 store_opts: [name: spoof_name],
                 checkpoint_store_opts: [
                   store: SpoofStore,
                   store_name: spoof_name
                 ]
               )

      assert_receive {:ckpt_cfg_probe, "task", ^run_id, _}, 2_000

      assert MemoryStore.stats(real_name).puts >= 1
      assert SpoofStore.stats(spoof_name).puts == 0
    end

    test "store:nil remains explicit file-only (no MemoryStore traffic)" do
      store_name = unique_store_name("ckpt_cfg_nil")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})

      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: nil,
        store_name: store_name,
        start_store: false
      )

      logs_root = tmp_logs("ckpt_cfg_nil")
      run_id = "ckpt_cfg_nil_#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _} =
               Engine.run(parse!(side_dot()),
                 run_id: run_id,
                 logs_root: logs_root,
                 parent: self(),
                 resumable: true
               )

      assert_receive {:ckpt_cfg_probe, "task", ^run_id, _}, 2_000

      stats = MemoryStore.stats(store_name)
      assert stats.puts == 0
      assert stats.deletes == 0
      assert stats.keys == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_store_name(label) do
    :"#{label}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp checkpoint_key(run_id), do: "checkpoint:#{run_id}"

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_ckpt_cfg_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp side_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="ckpt_cfg_side"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp block_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="ckpt_cfg_block"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp parse!(dot) do
    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    graph
  end
end
