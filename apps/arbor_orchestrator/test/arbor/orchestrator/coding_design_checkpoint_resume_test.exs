defmodule Arbor.Orchestrator.CodingDesignCheckpointResumeTest do
  @moduledoc """
  Crash/replay coverage for the coding design-checkpoint Open -> Await boundary.

  The graph intentionally uses the production action dispatch names and the
  same prefixed request-id handoff as coding-change-v1.dot. The action executor
  and stores are test-owned; no production hooks are required.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  # Persists the journal value before holding its reply. This gives the test an
  # explicit crash boundary without depending on scheduler timing.
  defmodule HoldStore do
    @moduledoc false
    use GenServer

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      GenServer.start_link(
        __MODULE__,
        %{
          data: %{},
          hold_node: Keyword.fetch!(opts, :hold_node),
          parent: Keyword.fetch!(opts, :parent),
          held_from: nil,
          held?: false
        },
        name: Keyword.fetch!(opts, :name)
      )
    end

    def put(key, value, opts),
      do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value}, :infinity)

    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def release(name), do: GenServer.call(name, :release)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, key, value}, from, state) do
      next = %{state | data: Map.put(state.data, key, value)}

      if not state.held? and completed_progress?(value, state.hold_node) do
        send(state.parent, {:journal_persisted_and_held, state.hold_node})
        {:noreply, %{next | held?: true, held_from: from}}
      else
        {:reply, :ok, next}
      end
    end

    def handle_call({:get, key}, _from, state) do
      case Map.fetch(state.data, key) do
        {:ok, value} -> {:reply, {:ok, value}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

    def handle_call({:delete, key}, _from, state),
      do: {:reply, :ok, %{state | data: Map.delete(state.data, key)}}

    def handle_call(:release, _from, %{held_from: nil} = state), do: {:reply, :ok, state}

    def handle_call(:release, _from, %{held_from: from} = state) do
      GenServer.reply(from, :ok)
      {:reply, :ok, %{state | held_from: nil}}
    end

    defp completed_progress?(value, node_id) do
      data = lifecycle_data(value)
      effect = data["current_effect"]

      is_map(effect) and effect["status"] == "completed" and effect["node_id"] == node_id and
        node_id in List.wrap(data["completed_nodes"])
    end

    defp lifecycle_data(%PersistenceRecord{data: data}) when is_map(data), do: data
    defp lifecycle_data(%{data: data}) when is_map(data), do: data
    defp lifecycle_data(data) when is_map(data), do: data
    defp lifecycle_data(_), do: %{}
  end

  # A process-independent action ledger. The Engine process may die; this
  # process preserves invocations and the exact Open/Await payloads.
  defmodule ActionStore do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      key = Keyword.fetch!(opts, :key)
      GenServer.start_link(__MODULE__, Map.new(opts), name: via(key))
    end

    def open(key, args), do: GenServer.call(via(key), {:open, args})
    def await(key, args), do: GenServer.call(via(key), {:await, args}, :infinity)
    def events(key), do: GenServer.call(via(key), :events)
    def unblock(key), do: GenServer.call(via(key), :unblock)

    @impl true
    def init(opts) do
      {:ok,
       %{
         parent: Map.fetch!(opts, :parent),
         request_id: Map.fetch!(opts, :request_id),
         open_evidence: Map.fetch!(opts, :open_evidence),
         terminal_evidence: Map.fetch!(opts, :terminal_evidence),
         await_mode: Map.get(opts, :await_mode, :return),
         events: [],
         blocked_from: nil
       }}
    end

    @impl true
    def handle_call({:open, args}, _from, state) do
      event = {:open, args}
      send(state.parent, {:design_checkpoint_action, :open, args})

      {:reply,
       {:ok,
        %{
          "checkpoint_outcome" => "pending",
          "request_id" => state.request_id,
          "evidence" => state.open_evidence
        }}, %{state | events: state.events ++ [event]}}
    end

    def handle_call({:await, args}, from, state) do
      event = {:await, args}
      send(state.parent, {:design_checkpoint_action, :await, args})
      state = %{state | events: state.events ++ [event]}

      case state.await_mode do
        :block ->
          {:noreply, %{state | blocked_from: from}}

        :return ->
          {:reply, terminal_result(state), state}
      end
    end

    def handle_call(:events, _from, state), do: {:reply, state.events, state}

    def handle_call(:unblock, _from, %{blocked_from: nil} = state), do: {:reply, :ok, state}

    def handle_call(:unblock, _from, %{blocked_from: from} = state) do
      GenServer.reply(from, terminal_result(state))
      {:reply, :ok, %{state | blocked_from: nil, await_mode: :return}}
    end

    defp terminal_result(state) do
      {:ok,
       %{
         "checkpoint_outcome" => "approve",
         "request_id" => state.request_id,
         "evidence" => state.terminal_evidence
       }}
    end

    defp via(key),
      do: {:via, Registry, {Arbor.Orchestrator.CodingDesignCheckpointResumeRegistry, key}}
  end

  defmodule ActionExecutor do
    @moduledoc false

    def execute("coding_design_checkpoint_open", %{"probe_key" => key} = args, _workdir, _opts),
      do: ActionStore.open(key, args)

    def execute("coding_design_checkpoint_await", %{"probe_key" => key} = args, _workdir, _opts),
      do: ActionStore.await(key, args)

    def execute(name, _args, _workdir, _opts), do: {:error, "unexpected action #{name}"}
  end

  defmodule CheckpointOutageStore do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
    end

    def durability_class(_opts), do: :node_restart

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, %{puts: 0}, name: Keyword.fetch!(opts, :name))

    def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    def get(_key, _opts), do: {:error, :not_found}
    def delete(_key, _opts), do: :ok
    def list(_opts), do: {:ok, []}

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, _key, _value}, _from, %{puts: 0} = state),
      do: {:reply, :ok, %{state | puts: 1}}

    def handle_call({:put, _key, _value}, _from, state),
      do: {:reply, {:error, :injected_checkpoint_outage}, %{state | puts: state.puts + 1}}
  end

  setup_all do
    {:ok, _} =
      Registry.start_link(
        keys: :unique,
        name: Arbor.Orchestrator.CodingDesignCheckpointResumeRegistry
      )

    :ok
  end

  setup do
    saved_checkpoint_config =
      Application.get_env(:arbor_orchestrator, :engine_checkpoints, :__unset__)

    on_exit(fn -> restore_checkpoint_config(saved_checkpoint_config) end)
    :ok
  end

  test "resume after Open checkpoint runs only Await with the persisted request identity and evidence" do
    configure_file_only_checkpoints!()
    probe = start_action_store!()
    harness = start_hold_journal!("open_checkpoint", "open_design_checkpoint")
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("open_checkpoint")
    dot = checkpoint_dot(probe.key)

    {engine_pid, mon} =
      spawn_engine(parse!(dot),
        run_id: harness.run_id,
        logs_root: logs_root,
        journal_opts: [server: harness.journal_name],
        identity_private_key: identity,
        resumable: true,
        actions_executor: ActionExecutor
      )

    assert_receive {:journal_persisted_and_held, "open_design_checkpoint"}, 5_000
    assert [open_event] = ActionStore.events(probe.key)
    assert {:open, _} = open_event
    assert File.exists?(Path.join(logs_root, "checkpoint.json"))

    kill_engine!(engine_pid, mon)
    :ok = HoldStore.release(harness.store_name)

    assert %Record{status: :interrupted} =
             PipelineStatus.get_record(harness.run_id, server: harness.journal_name)

    publish_interrupted_for_public_resume!(harness, logs_root, dot)

    assert {:ok, result} =
             Orchestrator.resume(harness.run_id,
               identity_private_key: identity,
               actions_executor: ActionExecutor
             )

    assert [{:open, _open_args}, {:await, await_args}] = ActionStore.events(probe.key)
    assert await_args["request_id"] == probe.request_id
    assert await_args["evidence"] == probe.open_evidence
    assert result.context["accepted_design_evidence"] == probe.terminal_evidence
  end

  test "blocked Await remains indeterminate on owner death and never reopens or re-awaits" do
    configure_file_only_checkpoints!()
    probe = start_action_store!(await_mode: :block)
    harness = start_journal!("await_pending")
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("await_pending")
    dot = checkpoint_dot(probe.key)

    {engine_pid, mon} =
      spawn_engine(parse!(dot),
        run_id: harness.run_id,
        logs_root: logs_root,
        journal_opts: [server: harness.journal_name],
        identity_private_key: identity,
        resumable: true,
        actions_executor: ActionExecutor
      )

    assert_receive {:design_checkpoint_action, :await, await_args}, 5_000
    assert await_args["request_id"] == probe.request_id
    assert await_args["evidence"] == probe.open_evidence

    pending = PipelineStatus.get_record(harness.run_id, server: harness.journal_name)
    assert pending.current_effect["status"] == "pending"
    assert pending.current_effect["node_id"] == "await_design_checkpoint"
    await_execution_id = pending.current_effect["execution_id"]

    kill_engine!(engine_pid, mon)
    :ok = ActionStore.unblock(probe.key)

    assert %Record{status: :interrupted} =
             PipelineStatus.get_record(harness.run_id, server: harness.journal_name)

    publish_interrupted_for_public_resume!(harness, logs_root, dot)

    assert {:error, {:indeterminate_effect, "await_design_checkpoint", ^await_execution_id}} =
             Orchestrator.resume(harness.run_id,
               identity_private_key: identity,
               actions_executor: ActionExecutor
             )

    assert [{:open, _}, {:await, ^await_args}] = ActionStore.events(probe.key)
  end

  test "terminal Await receipt resumes through accepted-evidence transform without replay" do
    configure_file_only_checkpoints!()
    probe = start_action_store!()
    harness = start_hold_journal!("await_receipt", "await_design_checkpoint")
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("await_receipt")
    dot = checkpoint_dot(probe.key)

    {engine_pid, mon} =
      spawn_engine(parse!(dot),
        run_id: harness.run_id,
        logs_root: logs_root,
        journal_opts: [server: harness.journal_name],
        identity_private_key: identity,
        resumable: true,
        actions_executor: ActionExecutor
      )

    assert_receive {:design_checkpoint_action, :await, await_args}, 5_000
    assert await_args["request_id"] == probe.request_id
    assert_receive {:journal_persisted_and_held, "await_design_checkpoint"}, 5_000

    kill_engine!(engine_pid, mon)
    :ok = HoldStore.release(harness.store_name)
    interrupted = PipelineStatus.get_record(harness.run_id, server: harness.journal_name)
    assert %Record{status: :interrupted} = interrupted
    assert interrupted.current_effect["status"] == "completed"
    assert interrupted.current_effect["node_id"] == "await_design_checkpoint"

    publish_interrupted_for_public_resume!(harness, logs_root, dot)

    assert {:ok, result} =
             Orchestrator.resume(harness.run_id,
               identity_private_key: identity,
               actions_executor: ActionExecutor
             )

    assert [{:open, _}, {:await, ^await_args}] = ActionStore.events(probe.key)
    assert result.context["accepted_design_evidence"] == probe.terminal_evidence
    assert result.context["accepted_design_request_id"] == probe.request_id
  end

  test "checkpoint persistence outage after Open fails closed before Await" do
    outage_store = unique_name("checkpoint_outage")
    {:ok, _} = start_supervised({CheckpointOutageStore, name: outage_store})

    Application.put_env(:arbor_orchestrator, :engine_checkpoints,
      store: CheckpointOutageStore,
      store_name: outage_store,
      start_store: false,
      store_child_opts: []
    )

    probe = start_action_store!()
    run_id = unique_run_id("checkpoint_outage")
    logs_root = tmp_logs("checkpoint_outage")

    assert {:error, {:effect_checkpoint_failed, _}} =
             Engine.run(parse!(checkpoint_dot(probe.key)),
               run_id: run_id,
               logs_root: logs_root,
               identity_private_key: :crypto.strong_rand_bytes(32),
               resumable: true,
               actions_executor: ActionExecutor
             )

    assert [{:open, _}] = ActionStore.events(probe.key)
    assert PipelineStatus.get_record(run_id).current_effect["status"] == "completed"
    refute_receive {:design_checkpoint_action, :await, _}, 100
  end

  defp start_action_store!(opts \\ []) do
    key = "design_checkpoint_probe_#{System.unique_integer([:positive, :monotonic])}"
    request_id = "design_request_#{System.unique_integer([:positive, :monotonic])}"
    open_evidence = %{"kind" => "open", "nonce" => key}
    terminal_evidence = %{"kind" => "approved", "nonce" => key}

    {:ok, _pid} =
      start_supervised(
        {ActionStore,
         [
           key: key,
           parent: self(),
           request_id: request_id,
           open_evidence: open_evidence,
           terminal_evidence: terminal_evidence
         ] ++ opts}
      )

    %{
      key: key,
      request_id: request_id,
      open_evidence: open_evidence,
      terminal_evidence: terminal_evidence
    }
  end

  defp start_journal!(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = unique_name("#{label}_journal_#{suffix}")
    ets_table = unique_name("#{label}_hot_#{suffix}")
    run_id = unique_run_id(label)
    {:ok, _} = start_supervised({RunJournal, name: journal_name, ets_table: ets_table})

    on_exit(fn -> cleanup_journal(run_id, journal_name) end)
    %{journal_name: journal_name, run_id: run_id}
  end

  defp start_hold_journal!(label, hold_node) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = unique_name("#{label}_journal_#{suffix}")
    ets_table = unique_name("#{label}_hot_#{suffix}")
    store_name = unique_name("#{label}_store_#{suffix}")
    run_id = unique_run_id(label)

    {:ok, _} =
      start_supervised({HoldStore, name: store_name, hold_node: hold_node, parent: self()})

    {:ok, _} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: HoldStore,
         store_name: store_name,
         start_store: false}
      )

    on_exit(fn ->
      _ = safe_release(store_name)
      cleanup_journal(run_id, journal_name)
    end)

    %{journal_name: journal_name, store_name: store_name, run_id: run_id}
  end

  defp publish_interrupted_for_public_resume!(harness, logs_root, dot) do
    dir = Path.join(System.tmp_dir!(), "arbor_design_checkpoint_dot_#{harness.run_id}")
    path = Path.join(dir, "pipeline.dot")
    :ok = File.mkdir_p(dir)
    :ok = File.write(path, dot)
    hash = :crypto.hash(:sha256, dot) |> Base.encode16(case: :lower)

    isolated = PipelineStatus.get_record(harness.run_id, server: harness.journal_name)
    assert %Record{status: :interrupted} = isolated

    published = %Record{
      isolated
      | failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: logs_root,
        dot_source_path: path,
        graph_hash: hash
    }

    assert :ok = PipelineStatus.put(published)

    on_exit(fn ->
      _ = PipelineStatus.delete(harness.run_id)
      _ = File.rm_rf(dir)
    end)
  end

  defp checkpoint_dot(probe_key) do
    """
    digraph DesignCheckpointResume {
      start [shape=Mdiamond]
      open_design_checkpoint [
        type="exec",
        target="action",
        action="coding_design_checkpoint_open",
        param.probe_key="#{probe_key}",
        output_prefix="design_checkpoint_open"
      ]
      hoist_design_checkpoint_request_id [
        type="transform",
        transform="identity",
        source_key="design_checkpoint_open.request_id",
        output_key="request_id"
      ]
      await_design_checkpoint [
        type="exec",
        target="action",
        action="coding_design_checkpoint_await",
        param.probe_key="#{probe_key}",
        context_keys="request_id,design_checkpoint_open.evidence",
        output_prefix="design_checkpoint"
      ]
      hoist_accepted_design_evidence [
        type="transform",
        transform="identity",
        source_key="design_checkpoint.evidence",
        output_key="accepted_design_evidence"
      ]
      hoist_accepted_design_request_id [
        type="transform",
        transform="identity",
        source_key="design_checkpoint.request_id",
        output_key="accepted_design_request_id"
      ]
      exit [shape=Msquare]

      start -> open_design_checkpoint -> hoist_design_checkpoint_request_id -> await_design_checkpoint
      await_design_checkpoint -> hoist_accepted_design_evidence -> hoist_accepted_design_request_id -> exit
    }
    """
  end

  defp spawn_engine(graph, opts) do
    parent = self()

    spawn_monitor(fn ->
      result = Engine.run(graph, opts)
      send(parent, {:engine_finished, self(), result})
    end)
  end

  defp kill_engine!(pid, mon) do
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^mon, :process, ^pid, :killed}, 2_000
    refute Process.alive?(pid)

    receive do
      {:engine_finished, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp parse!(dot) do
    assert {:ok, graph} = Orchestrator.parse(dot)
    graph
  end

  defp configure_file_only_checkpoints! do
    Application.put_env(:arbor_orchestrator, :engine_checkpoints,
      store: nil,
      store_name: :unused_design_checkpoint_resume,
      start_store: false
    )
  end

  defp restore_checkpoint_config(:__unset__),
    do: Application.delete_env(:arbor_orchestrator, :engine_checkpoints)

  defp restore_checkpoint_config(value),
    do: Application.put_env(:arbor_orchestrator, :engine_checkpoints, value)

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")

  defp unique_run_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_design_checkpoint_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp cleanup_journal(run_id, journal_name) do
    try do
      _ = PipelineStatus.delete(run_id, server: journal_name)
    catch
      :exit, _ -> :ok
    end
  end

  defp safe_release(store_name) do
    try do
      HoldStore.release(store_name)
    catch
      :exit, _ -> :ok
    end
  end
end
