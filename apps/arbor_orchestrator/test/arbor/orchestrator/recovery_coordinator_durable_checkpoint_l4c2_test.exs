defmodule Arbor.Orchestrator.RecoveryCoordinatorDurableCheckpointL4C2Test do
  @moduledoc """
  L4C2: RecoveryCoordinator locates durable checkpoints via Config-owned store
  opts captured at init, not a hardcoded BufferedStore name.

  Proves:
  - custom configured backend/name is used
  - caller/resolver store spoof keys cannot redirect lookup
  - exact checkpoint:<run_id> envelope key + payload run_id binding
  - peer fallback only for :not_found / :store_not_configured
  - outage / corruption / mismatch fail closed (no peer)
  - local checkpoint.json wins over durable store
  - explicit / derived HMAC is honored
  - malformed Config is an explicit captured failure
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.RecoveryCoordinator
  alias Arbor.Orchestrator.RunLifecycle.Record

  defmodule MemoryStore do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)
      %{id: name, start: {__MODULE__, :start_link, [opts]}}
    end

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{data: %{}, gets: 0, fail: nil}, name: name)
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
      do: {:reply, %{gets: state.gets, keys: Map.keys(state.data)}, state}

    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
    end

    def handle_call({:get, _key}, _from, %{fail: :get} = state) do
      {:reply, {:error, :injected_get_outage}, %{state | gets: state.gets + 1}}
    end

    def handle_call({:get, _key}, _from, %{fail: :raise} = state) do
      _ = %{state | gets: state.gets + 1}
      raise "injected durable get raise"
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

  setup do
    saved_env = Application.get_env(:arbor_orchestrator, :engine_checkpoints, :__unset__)

    on_exit(fn ->
      case saved_env do
        :__unset__ -> Application.delete_env(:arbor_orchestrator, :engine_checkpoints)
        value -> Application.put_env(:arbor_orchestrator, :engine_checkpoints, value)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Happy path: custom Config-owned backend/name
  # ---------------------------------------------------------------------------

  describe "durable store via captured Config opts" do
    test "custom configured backend/name returns exact {:store, map}" do
      store_name = unique_store("ok")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, run_id, graph_hash} = prepare_logs!("ok")
      seed_durable!(logs_root, run_id, identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))
      refute File.exists?(Path.join(logs_root, "checkpoint.json"))

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)
      hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)

      assert {:ok, {:store, payload}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state,
                 hmac_secret: hmac,
                 identity_private_key: identity
               )

      assert is_map(payload)
      assert payload["run_id"] == run_id
      assert payload["current_node"] == "start"
      assert Map.has_key?(MemoryStore.dump(store_name), checkpoint_key(run_id))
    end

    test "local checkpoint.json wins over durable store" do
      store_name = unique_store("local_wins")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, run_id, graph_hash} = prepare_logs!("local_wins")
      seed_durable!(logs_root, run_id, identity, graph_hash)

      local_path = Path.join(logs_root, "checkpoint.json")
      assert File.exists?(local_path)
      File.write!(local_path, ~s({"run_id":"#{run_id}","source":"local_file"}))

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)
      gets_before = MemoryStore.stats(store_name).gets

      assert {:ok, {:file, ^local_path}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state,
                 identity_private_key: identity
               )

      # Durable store must not be consulted when local file exists.
      assert MemoryStore.stats(store_name).gets == gets_before
    end

    test "HMAC secret is honored; wrong secret fails closed without peer" do
      store_name = unique_store("hmac")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      good = :crypto.strong_rand_bytes(32)
      bad = :crypto.strong_rand_bytes(32)
      {logs_root, run_id, graph_hash} = prepare_logs!("hmac")
      seed_durable!(logs_root, run_id, good, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, :checkpoint_hmac_invalid} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state,
                 identity_private_key: bad
               )

      good_hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: good)

      assert {:ok, {:store, %{"run_id" => ^run_id}}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state,
                 hmac_secret: good_hmac
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Security: store target spoof ignored
  # ---------------------------------------------------------------------------

  describe "store target binding (security regression)" do
    test "caller store/store_name/store_opts cannot redirect durable lookup" do
      real_name = unique_store("real")
      spoof_name = unique_store("spoof")
      {:ok, _} = start_supervised({MemoryStore, name: real_name})
      {:ok, _} = start_supervised({SpoofStore, name: spoof_name})
      configure_store!(MemoryStore, real_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, run_id, graph_hash} = prepare_logs!("spoof")
      seed_durable!(logs_root, run_id, identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

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

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)
      real_gets_before = MemoryStore.stats(real_name).gets
      spoof_gets_before = SpoofStore.stats(spoof_name).gets
      hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)

      assert {:ok, {:store, payload}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state,
                 hmac_secret: hmac,
                 store: SpoofStore,
                 store_name: spoof_name,
                 store_opts: [name: spoof_name],
                 checkpoint_store_opts: [store: SpoofStore, store_name: spoof_name]
               )

      assert payload["current_node"] == "start"
      assert MemoryStore.stats(real_name).gets > real_gets_before
      assert SpoofStore.stats(spoof_name).gets == spoof_gets_before
    end
  end

  # ---------------------------------------------------------------------------
  # Exact identity binding
  # ---------------------------------------------------------------------------

  describe "exact envelope and payload binding" do
    test "bare run_id key is not a durable checkpoint" do
      store_name = unique_store("bare")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, run_id, _hash} = prepare_logs!("bare")
      File.rm_rf!(Path.join(logs_root, "checkpoint.json"))

      :ok =
        MemoryStore.put(
          run_id,
          PersistenceRecord.new(run_id, minimal_payload(run_id)),
          name: store_name
        )

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, :checkpoint_not_found} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])
    end

    test "wrong envelope key fails closed without peer fallback" do
      store_name = unique_store("env_key")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, run_id, _hash} = prepare_logs!("env_key")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      key = checkpoint_key(run_id)

      mismatched =
        PersistenceRecord.new("checkpoint:other_run", minimal_payload(run_id))

      :ok = MemoryStore.put(key, mismatched, name: store_name)

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, :checkpoint_key_mismatch} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])

      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(:checkpoint_key_mismatch) ==
               true
    end

    test "wrong payload run_id fails closed without peer fallback" do
      store_name = unique_store("payload")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, run_id, _hash} = prepare_logs!("payload")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      key = checkpoint_key(run_id)
      foreign = minimal_payload("foreign_run_id")
      :ok = MemoryStore.put(key, PersistenceRecord.new(key, foreign), name: store_name)

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, :checkpoint_run_id_mismatch} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])

      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(
               :checkpoint_run_id_mismatch
             ) == true
    end

    test "corrupt non-map payload fails closed as checkpoint_corrupt" do
      store_name = unique_store("corrupt")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, run_id, _hash} = prepare_logs!("corrupt")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      key = checkpoint_key(run_id)
      :ok = MemoryStore.put(key, "not-a-checkpoint-map", name: store_name)

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, {:checkpoint_corrupt, :invalid_checkpoint_payload}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])

      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:checkpoint_corrupt, :invalid_checkpoint_payload}
             ) == true
    end
  end

  # ---------------------------------------------------------------------------
  # Peer fallback gate
  # ---------------------------------------------------------------------------

  describe "peer fallback only for not_found / store_not_configured" do
    test "missing durable checkpoint is checkpoint_not_found (peer may run; none present)" do
      store_name = unique_store("missing")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, run_id, _hash} = prepare_logs!("missing")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, :checkpoint_not_found} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])
    end

    test "store:nil Config permits peer-path absence as checkpoint_not_found" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints,
        store: nil,
        store_name: :unused_l4c2,
        start_store: false
      )

      {logs_root, run_id, _hash} = prepare_logs!("store_nil")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      state = locator_state_from_config!()
      assert match?({:ok, opts} when is_list(opts), state.checkpoint_store_opts)
      assert Keyword.get(elem(state.checkpoint_store_opts, 1), :store) == nil

      entry = record(run_id, logs_root)

      assert {:error, :checkpoint_not_found} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])
    end

    test "store outage fails closed as store_unavailable — not peer / not_found" do
      store_name = unique_store("outage")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      identity = :crypto.strong_rand_bytes(32)
      {logs_root, run_id, graph_hash} = prepare_logs!("outage")
      seed_durable!(logs_root, run_id, identity, graph_hash)
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      :ok = MemoryStore.set_fail(store_name, :get)

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, {:store_unavailable, _}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state,
                 identity_private_key: identity
               )

      refute RecoveryCoordinator.__test_non_retryable_recovery_error__(
               {:store_unavailable, :injected_get_outage}
             )
    end

    test "raise during durable get fails closed as store_unavailable" do
      store_name = unique_store("raise")
      {:ok, _} = start_supervised({MemoryStore, name: store_name})
      configure_store!(MemoryStore, store_name)

      {logs_root, run_id, _hash} = prepare_logs!("raise")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      key = checkpoint_key(run_id)

      :ok =
        MemoryStore.put(key, PersistenceRecord.new(key, minimal_payload(run_id)),
          name: store_name
        )

      :ok = MemoryStore.set_fail(store_name, :raise)

      state = locator_state_from_config!()
      entry = record(run_id, logs_root)

      assert {:error, {:store_unavailable, _}} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed Config
  # ---------------------------------------------------------------------------

  describe "malformed Config capture" do
    test "malformed engine_checkpoints is explicit and never substitutes defaults" do
      Application.put_env(:arbor_orchestrator, :engine_checkpoints, :malformed)

      assert {:error, {:invalid_engine_checkpoints, _}} =
               RecoveryCoordinator.__test_capture_checkpoint_store_opts__()

      {logs_root, run_id, _hash} = prepare_logs!("bad_cfg")
      File.rm!(Path.join(logs_root, "checkpoint.json"))

      state = %{
        checkpoint_store_opts: RecoveryCoordinator.__test_capture_checkpoint_store_opts__()
      }

      entry = record(run_id, logs_root)

      assert {:error, reason} =
               RecoveryCoordinator.__test_locate_checkpoint__(entry, state, [])

      assert match?({:invalid_engine_checkpoints, _}, reason)
      assert RecoveryCoordinator.__test_non_retryable_recovery_error__(reason) == true
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
    :"l4c2_rc_#{label}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp checkpoint_key(run_id), do: "checkpoint:#{run_id}"

  defp locator_state_from_config! do
    case RecoveryCoordinator.__test_capture_checkpoint_store_opts__() do
      {:ok, _} = ok ->
        %{checkpoint_store_opts: ok}

      {:error, _} = err ->
        %{checkpoint_store_opts: err}
    end
  end

  defp record(run_id, logs_root) do
    %Record{
      run_id: run_id,
      pipeline_id: run_id,
      status: :interrupted,
      logs_root: logs_root,
      owner_node: nil
    }
  end

  defp prepare_logs!(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    run_id = "l4c2_rc_#{label}_#{suffix}"

    logs_root =
      Path.join(System.tmp_dir!(), "arbor_l4c2_rc_#{label}_#{suffix}")

    File.mkdir_p!(logs_root)
    on_exit(fn -> File.rm_rf(logs_root) end)

    # Local placeholder so tests that delete it exercise durable-only path.
    File.write!(Path.join(logs_root, "checkpoint.json"), "{}")

    graph_hash =
      :crypto.hash(:sha256, "digraph { start -> exit }")
      |> Base.encode16(case: :lower)

    {logs_root, run_id, graph_hash}
  end

  defp seed_durable!(logs_root, run_id, identity, graph_hash) do
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

    opts =
      Config.engine_checkpoint_store_opts()
      |> Keyword.put(:hmac_secret, hmac)

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, opts)
  end

  defp minimal_payload(run_id) do
    %{
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
    }
  end
end
