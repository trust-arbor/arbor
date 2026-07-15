defmodule Arbor.Orchestrator.EnginePublicDurableResumeL4C2bTest do
  @moduledoc """
  L4C2b: public Orchestrator.list_resumable/0 and resume/2 observe Config-owned
  durable checkpoints when local checkpoint.json is absent.

  Proves:
  - durable-only checkpoints appear in list_resumable and resume with zero
    duplicate side-effect invocation
  - exact checkpoint:<run_id> lookup + envelope/payload binding
  - missing / store:nil / outage / wrong key / wrong payload run_id / wrong HMAC
    fail closed with bounded errors
  - caller-supplied store targets cannot redirect public resume
  - local-file compatibility remains
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.PipelineStatus

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

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{data: %{}, gets: 0, puts: 0, fail: nil}, name: name)
    end

    def put(key, value, opts),
      do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})

    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def set_fail(name, fail), do: GenServer.call(name, {:set_fail, fail})
    def dump(name), do: GenServer.call(name, :dump)
    def stats(name), do: GenServer.call(name, :stats)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:set_fail, fail}, _from, state), do: {:reply, :ok, %{state | fail: fail}}
    def handle_call(:dump, _from, state), do: {:reply, state.data, state}

    def handle_call(:stats, _from, state),
      do: {:reply, %{gets: state.gets, puts: state.puts, keys: Map.keys(state.data)}, state}

    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, %{state | data: Map.put(state.data, key, value), puts: state.puts + 1}}
    end

    def handle_call({:get, _key}, _from, %{fail: :get} = state) do
      {:reply, {:error, :injected_get_outage}, %{state | gets: state.gets + 1}}
    end

    def handle_call({:get, key}, _from, state) do
      state = %{state | gets: state.gets + 1}

      case Map.fetch(state.data, key) do
        {:ok, v} -> {:reply, {:ok, v}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, key}, _from, state) do
      {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
    end

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}
  end

  defmodule SpoofStore do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)
      %{id: name, start: {__MODULE__, :start_link, [opts]}}
    end

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, %{data: %{}, gets: 0}, name: opts[:name])

    def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def stats(name), do: GenServer.call(name, :stats)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
    end

    def handle_call({:get, key}, _from, state) do
      state = %{state | gets: state.gets + 1}

      case Map.fetch(state.data, key) do
        {:ok, v} -> {:reply, {:ok, v}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, key}, _from, state) do
      {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
    end

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}
    def handle_call(:stats, _from, state), do: {:reply, %{gets: state.gets}, state}
  end

  defmodule SideProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      if parent = opts[:parent] do
        send(parent, {:l4c2b_probe, node.id, opts[:run_id], opts[:execution_id]})
      end

      counter = Keyword.get(opts, :invoke_counter)

      if is_pid(counter) or is_atom(counter) do
        try do
          Agent.update(counter, &(&1 + 1))
        catch
          :exit, _ -> :ok
        end
      end

      %Outcome{status: :success, context_updates: %{"probe" => node.id}}
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
    :ok = Registry.register("l4c2b_side", SideProbe)
    on_exit(fn -> Registry.restore_custom_handlers(saved_handlers) end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Happy path: durable-only list + resume (zero duplicate side effects)
  # ---------------------------------------------------------------------------

  describe "durable-only public list/resume" do
    test "durable-only checkpoint appears in list_resumable and resumes without replaying side effects" do
      store_name = unique_store("durable_ok")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, _dot_path, graph_hash, run_id} = prepare_interrupted!("durable_ok")

      # Seed durable store only — remove compatibility file.
      seed_start_checkpoint!(logs_root, run_id, identity, graph_hash)
      assert File.exists?(Path.join(logs_root, "checkpoint.json"))
      File.rm!(Path.join(logs_root, "checkpoint.json"))
      refute File.exists?(Path.join(logs_root, "checkpoint.json"))

      assert Map.has_key?(MemoryStore.dump(store_name), checkpoint_key(run_id))

      assert {:ok, resumable} = Orchestrator.list_resumable()
      match = Enum.find(resumable, &(&1.run_id == run_id))
      assert match
      assert match.status == :interrupted
      assert match.logs_root == logs_root

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert {:ok, result} =
               Orchestrator.resume(run_id,
                 parent: self(),
                 identity_private_key: identity,
                 invoke_counter: counter
               )

      assert_receive {:l4c2b_probe, "task", ^run_id, _}, 2_000
      assert Agent.get(counter, & &1) == 1
      assert "exit" in result.completed_nodes

      final = PipelineStatus.get_record(run_id)
      assert final.status == :completed

      # Second list after completion must not include it.
      assert {:ok, after_done} = Orchestrator.list_resumable()
      refute Enum.any?(after_done, &(&1.run_id == run_id))
    end

    test "existing local checkpoint.json remains resumable without durable store entry" do
      # File-only Config: durable fetch is store_not_configured → not used.
      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: nil,
        store_name: :unused_l4c2b,
        start_store: false
      )

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, _dot_path, graph_hash, run_id} = prepare_interrupted!("local_file")

      seed_start_checkpoint!(logs_root, run_id, identity, graph_hash, store: nil)
      assert File.exists?(Path.join(logs_root, "checkpoint.json"))

      assert {:ok, resumable} = Orchestrator.list_resumable()
      assert Enum.any?(resumable, &(&1.run_id == run_id))

      assert {:ok, result} =
               Orchestrator.resume(run_id,
                 parent: self(),
                 identity_private_key: identity
               )

      assert_receive {:l4c2b_probe, "task", ^run_id, _}, 2_000
      assert "exit" in result.completed_nodes
    end
  end

  # ---------------------------------------------------------------------------
  # Exact key / envelope / payload binding
  # ---------------------------------------------------------------------------

  describe "exact durable identity binding" do
    test "list uses exact checkpoint:<run_id> key; bare run_id alone is not resumable" do
      store_name = unique_store("exact_key")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, _dot, _hash, run_id} = prepare_interrupted!("exact_key")
      File.rm_rf!(Path.join(logs_root, "checkpoint.json"))

      # Only bare run_id key — must not count as durable checkpoint.
      :ok =
        MemoryStore.put(
          run_id,
          PersistenceRecord.new(run_id, %{
            "run_id" => run_id,
            "current_node" => "start",
            "timestamp" => "2026-07-15T00:00:00Z",
            "completed_nodes" => ["start"],
            "node_retries" => %{},
            "context_values" => %{},
            "context_taint" => %{},
            "node_outcomes" => %{},
            "context_lineage" => %{},
            "content_hashes" => %{},
            "pending_intents" => %{},
            "execution_digests" => %{}
          }),
          name: store_name
        )

      assert {:ok, resumable} = Orchestrator.list_resumable()
      refute Enum.any?(resumable, &(&1.run_id == run_id))

      assert {:error, :checkpoint_not_found} =
               Orchestrator.resume(run_id, identity_private_key: :crypto.strong_rand_bytes(32))

      rec = PipelineStatus.get_record(run_id)
      assert rec.status == :interrupted
    end

    test "wrong envelope key fails closed on list (bounded error, not silent omit)" do
      store_name = unique_store("wrong_key")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, _dot, _hash, run_id} = prepare_interrupted!("wrong_key")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      key = checkpoint_key(run_id)

      mismatched =
        PersistenceRecord.new("checkpoint:other_run", %{
          "run_id" => run_id,
          "current_node" => "start",
          "timestamp" => "2026-07-15T00:00:00Z",
          "completed_nodes" => ["start"],
          "node_retries" => %{},
          "context_values" => %{},
          "context_taint" => %{},
          "node_outcomes" => %{},
          "context_lineage" => %{},
          "content_hashes" => %{},
          "pending_intents" => %{},
          "execution_digests" => %{}
        })

      :ok = MemoryStore.put(key, mismatched, name: store_name)

      assert {:error, {:durable_checkpoint, :checkpoint_key_mismatch}} =
               Orchestrator.list_resumable()
    end

    test "wrong payload run_id fails closed on list" do
      store_name = unique_store("wrong_payload")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, _dot, _hash, run_id} = prepare_interrupted!("wrong_payload")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      key = checkpoint_key(run_id)

      foreign = %{
        "timestamp" => "2026-07-15T00:00:00Z",
        "run_id" => "foreign_run_id",
        "current_node" => "start",
        "completed_nodes" => ["start"],
        "node_retries" => %{},
        "context_values" => %{},
        "context_taint" => %{},
        "node_outcomes" => %{},
        "context_lineage" => %{},
        "content_hashes" => %{},
        "pending_intents" => %{},
        "execution_digests" => %{}
      }

      :ok = MemoryStore.put(key, PersistenceRecord.new(key, foreign), name: store_name)

      assert {:error, {:durable_checkpoint, :checkpoint_run_id_mismatch}} =
               Orchestrator.list_resumable()
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed preflight (never claim / leave interrupted)
  # ---------------------------------------------------------------------------

  describe "durable preflight fails closed" do
    test "missing durable checkpoint is checkpoint_not_found and leaves interrupted" do
      store_name = unique_store("missing")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, _dot, _hash, run_id} = prepare_interrupted!("missing")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      assert {:ok, resumable} = Orchestrator.list_resumable()
      refute Enum.any?(resumable, &(&1.run_id == run_id))

      assert {:error, :checkpoint_not_found} =
               Orchestrator.resume(run_id, identity_private_key: :crypto.strong_rand_bytes(32))

      assert PipelineStatus.get_record(run_id).status == :interrupted
    end

    test "store:nil Config treats durable path as absent (local file still works elsewhere)" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: nil,
        store_name: :unused,
        start_store: false
      )

      {logs_root, _dot, _hash, run_id} = prepare_interrupted!("store_nil")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      assert {:ok, resumable} = Orchestrator.list_resumable()
      refute Enum.any?(resumable, &(&1.run_id == run_id))

      assert {:error, :checkpoint_not_found} =
               Orchestrator.resume(run_id, identity_private_key: :crypto.strong_rand_bytes(32))

      assert PipelineStatus.get_record(run_id).status == :interrupted
    end

    test "store outage surfaces bounded error on list and resume; never recovering" do
      store_name = unique_store("outage")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, _dot, graph_hash, run_id} = prepare_interrupted!("outage")
      identity = :crypto.strong_rand_bytes(32)
      seed_start_checkpoint!(logs_root, run_id, identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      :ok = MemoryStore.set_fail(store_name, :get)

      assert {:error, {:durable_checkpoint, {:store_unavailable, _}}} =
               Orchestrator.list_resumable()

      assert {:error, {:durable_checkpoint, {:store_unavailable, _}}} =
               Orchestrator.resume(run_id, identity_private_key: identity)

      assert PipelineStatus.get_record(run_id).status == :interrupted
      refute PipelineStatus.get_record(run_id).status == :recovering
    end

    test "wrong HMAC fails closed before claim" do
      store_name = unique_store("bad_hmac")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      good_identity = :crypto.strong_rand_bytes(32)
      bad_identity = :crypto.strong_rand_bytes(32)
      {logs_root, _dot, graph_hash, run_id} = prepare_interrupted!("bad_hmac")

      seed_start_checkpoint!(logs_root, run_id, good_identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      # Listing without HMAC still accepts exact identity binding.
      assert {:ok, resumable} = Orchestrator.list_resumable()
      assert Enum.any?(resumable, &(&1.run_id == run_id))

      assert {:error, :checkpoint_hmac_invalid} =
               Orchestrator.resume(run_id, identity_private_key: bad_identity)

      assert PipelineStatus.get_record(run_id).status == :interrupted
    end

    test "security regression: missing resume identity fails before claim" do
      store_name = unique_store("missing_identity")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, _dot, graph_hash, run_id} = prepare_interrupted!("missing_identity")

      seed_start_checkpoint!(logs_root, run_id, identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      assert {:error, :identity_required_for_resume} = Orchestrator.resume(run_id)
      assert PipelineStatus.get_record(run_id).status == :interrupted
    end

    test "malformed code-owned checkpoint config is explicit and never claims" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints, :malformed)

      {logs_root, _dot, _graph_hash, run_id} = prepare_interrupted!("bad_config")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      assert {:error, {:invalid_engine_checkpoints, _}} = Orchestrator.list_resumable()

      assert {:error, {:invalid_engine_checkpoints, _}} =
               Orchestrator.resume(run_id,
                 identity_private_key: :crypto.strong_rand_bytes(32)
               )

      assert PipelineStatus.get_record(run_id).status == :interrupted
    end

    test "caller-supplied store target cannot redirect public resume (security regression)" do
      real_name = unique_store("real")
      spoof_name = unique_store("spoof")
      {:ok, _} = start_supervised({MemoryStore, name: real_name})
      {:ok, _} = start_supervised({SpoofStore, name: spoof_name})
      configure_store!(MemoryStore, real_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, _dot, graph_hash, run_id} = prepare_interrupted!("spoof")

      seed_start_checkpoint!(logs_root, run_id, identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      # Poison spoof with a different payload under the same key — must never be read.
      spoof_key = checkpoint_key(run_id)

      :ok =
        SpoofStore.put(
          spoof_key,
          PersistenceRecord.new(spoof_key, %{
            "run_id" => run_id,
            "current_node" => "exit",
            "timestamp" => "2026-07-15T00:00:00Z",
            "completed_nodes" => ["start", "task", "exit"],
            "node_retries" => %{},
            "context_values" => %{},
            "context_taint" => %{},
            "node_outcomes" => %{},
            "context_lineage" => %{},
            "content_hashes" => %{},
            "pending_intents" => %{},
            "execution_digests" => %{}
          }),
          name: spoof_name
        )

      real_gets_before = MemoryStore.stats(real_name).gets
      spoof_gets_before = SpoofStore.stats(spoof_name).gets

      assert {:ok, result} =
               Orchestrator.resume(run_id,
                 parent: self(),
                 identity_private_key: identity,
                 store: SpoofStore,
                 store_name: spoof_name,
                 store_opts: [name: spoof_name],
                 checkpoint_store_opts: [
                   store: SpoofStore,
                   store_name: spoof_name
                 ]
               )

      # Real store was consulted; spoof was not.
      assert MemoryStore.stats(real_name).gets > real_gets_before
      assert SpoofStore.stats(spoof_name).gets == spoof_gets_before

      # Resumed from real start checkpoint → task still runs (not terminal spoof).
      assert_receive {:l4c2b_probe, "task", ^run_id, _}, 2_000
      assert "exit" in result.completed_nodes
      assert PipelineStatus.get_record(run_id).status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp configure_store!(store, store_name) do
    Application.put_env(:arbor_orchestrator, :engine_checkpoints,
      store: store,
      store_name: store_name,
      start_store: false,
      store_child_opts: []
    )
  end

  defp unique_store(label) do
    :"l4c2b_#{label}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp checkpoint_key(run_id), do: "checkpoint:#{run_id}"

  defp prepare_interrupted!(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    run_id = "l4c2b_#{label}_#{suffix}"

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_l4c2b_#{label}_#{suffix}"
      )

    File.mkdir_p!(logs_root)
    on_exit(fn -> File.rm_rf(logs_root) end)

    dot_path = Path.join(logs_root, "graph.dot")
    File.write!(dot_path, side_dot())
    graph_hash = :crypto.hash(:sha256, File.read!(dot_path)) |> Base.encode16(case: :lower)

    # Placeholder local file so prepare path is clean; tests remove it for durable-only.
    File.write!(Path.join(logs_root, "checkpoint.json"), "{}")

    :ok =
      PipelineStatus.put(%{
        run_id: run_id,
        pipeline_id: run_id,
        status: :interrupted,
        logs_root: logs_root,
        graph_hash: graph_hash,
        dot_source_path: dot_path,
        started_at: DateTime.utc_now(),
        total_nodes: 3,
        completed_count: 1,
        completed_nodes: ["start"],
        effect_generation: 0,
        current_effect: nil,
        owner_node: nil
      })

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {logs_root, dot_path, graph_hash, run_id}
  end

  defp seed_start_checkpoint!(logs_root, run_id, identity, graph_hash, extra \\ []) do
    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    context = Context.new(%{"outcome" => "success"})
    outcomes = %{"start" => %Outcome{status: :success}}

    checkpoint =
      Checkpoint.from_state("start", ["start"], %{}, context, outcomes,
        run_id: run_id,
        graph_hash: graph_hash,
        pipeline_started_at: DateTime.utc_now(),
        execution_digests: %{}
      )

    # Persist through Config-owned opts when store is configured (default), so
    # the same key/envelope shape Engine uses is exercised.
    opts =
      case Keyword.fetch(extra, :store) do
        :error ->
          Arbor.Orchestrator.Config.engine_checkpoint_store_opts()
          |> Keyword.put(:hmac_secret, hmac)

        {:ok, store} ->
          [store: store, hmac_secret: hmac]
          |> Keyword.merge(Keyword.delete(extra, :store))
      end

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, opts)
  end

  defp side_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l4c2b_side"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end
end
