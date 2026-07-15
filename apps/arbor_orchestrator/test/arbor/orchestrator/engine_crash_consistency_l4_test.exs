defmodule Arbor.Orchestrator.EngineCrashConsistencyL4Test do
  @moduledoc """
  L4A Engine-process crash-consistency proofs.

  Unlike L3B/L3C (returned persistence failures), these tests kill the real
  Engine caller process with an untrappable exit while RunJournal remains
  alive. A test-only hold store persists the matched transition then holds
  its reply so the Engine can be killed mid-protocol with durable evidence
  already retained.

  Protocol windows covered:
  1. After durable pending prepare, before external effect
  2. Mid multi-step effect after partial external progress
  3. After external effect completes, before handler return / receipt
  4. After durable completed receipt (+ authenticated checkpoint), before
     progress settle / graph advance — exact reconciliation without replay
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  # ---------------------------------------------------------------------------
  # Test-only hold store: persist matched transition, then hold the reply
  # ---------------------------------------------------------------------------

  defmodule HoldStore do
    @moduledoc false
    use GenServer

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      hold_on = Keyword.fetch!(opts, :hold_on)
      parent = Keyword.fetch!(opts, :parent)
      hold_node = Keyword.get(opts, :hold_node, "task")

      GenServer.start_link(
        __MODULE__,
        %{
          hold_on: hold_on,
          hold_node: hold_node,
          parent: parent,
          hold_fired?: false,
          held_from: nil,
          held_key: nil,
          data: %{}
        },
        name: name
      )
    end

    def put(key, value, opts) do
      # Infinity: Engine kill is the termination path; do not race GenServer timeout.
      GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value}, :infinity)
    end

    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})

    def release(name), do: GenServer.call(name, :release, 5_000)

    def held?(name), do: GenServer.call(name, :held?)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, key, value}, from, state) do
      new_data = Map.put(state.data, key, value)

      if not state.hold_fired? and matches_transition?(state.hold_on, state.hold_node, value) do
        send(
          state.parent,
          {:store_held, state.hold_on,
           %{
             key: key,
             effect: effect_from_value(value),
             completed_nodes: completed_nodes_from_value(value)
           }}
        )

        {:noreply,
         %{
           state
           | data: new_data,
             hold_fired?: true,
             held_from: from,
             held_key: key
         }}
      else
        {:reply, :ok, %{state | data: new_data}}
      end
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

    def handle_call(:held?, _from, state) do
      {:reply, is_tuple(state.held_from), state}
    end

    def handle_call(:release, _from, %{held_from: nil} = state) do
      {:reply, :ok, state}
    end

    def handle_call(:release, _from, %{held_from: from} = state) do
      GenServer.reply(from, :ok)
      {:reply, :ok, %{state | held_from: nil, held_key: nil}}
    end

    defp matches_transition?(hold_on, hold_node, value) do
      data = lifecycle_data(value)
      effect = data["current_effect"]
      completed = List.wrap(data["completed_nodes"])

      case hold_on do
        :prepare ->
          is_map(effect) and effect["status"] == "pending" and effect["node_id"] == hold_node

        :receipt ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == hold_node and
            hold_node not in completed

        :completed_progress ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == hold_node and
            hold_node in completed

        :settle ->
          is_map(effect) and effect["status"] == "settled" and effect["node_id"] == hold_node

        _ ->
          false
      end
    end

    defp effect_from_value(value) do
      data = lifecycle_data(value)
      data["current_effect"]
    end

    defp completed_nodes_from_value(value) do
      data = lifecycle_data(value)
      List.wrap(data["completed_nodes"])
    end

    defp lifecycle_data(%PersistenceRecord{data: data}) when is_map(data), do: data
    defp lifecycle_data(%{data: data}) when is_map(data), do: data
    defp lifecycle_data(data) when is_map(data), do: data
    defp lifecycle_data(_), do: %{}
  end

  # ---------------------------------------------------------------------------
  # Process-independent invocation counter (survives Engine death)
  # ---------------------------------------------------------------------------

  defmodule InvokeCounter do
    @moduledoc false
    use Agent

    def start_link(name), do: Agent.start_link(fn -> [] end, name: name)

    def record(name, event) when is_map(event) do
      Agent.update(name, fn events -> events ++ [event] end)
    end

    def events(name), do: Agent.get(name, & &1)

    def count(name), do: length(events(name))

    def reset(name), do: Agent.update(name, fn _ -> [] end)
  end

  # ---------------------------------------------------------------------------
  # Controllable probe handlers (test-only; no production hooks)
  # ---------------------------------------------------------------------------

  defmodule SideEffectProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      counter = opts[:invoke_counter]
      parent = opts[:parent]
      execution_id = opts[:execution_id]

      if counter,
        do: InvokeCounter.record(counter, %{node_id: node.id, execution_id: execution_id})

      if parent do
        send(parent, {:l4_probe, node.id, execution_id})
      end

      %Outcome{status: :success, context_updates: %{"probe.side" => node.id}}
    end
  end

  defmodule MultiStepProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      counter = opts[:invoke_counter]
      parent = opts[:parent]
      execution_id = opts[:execution_id]
      marker_path = opts[:effect_marker_path]

      if counter,
        do: InvokeCounter.record(counter, %{node_id: node.id, execution_id: execution_id})

      # Partial externally observable progress before blocking.
      if is_binary(marker_path) do
        :ok = File.write(marker_path, "partial:#{execution_id}\n")
      end

      if parent do
        send(parent, {:l4_partial, node.id, execution_id, marker_path})
      end

      # Block until Engine process is killed (untrappable owner death).
      receive do
        :l4_must_not_continue -> :ok
      after
        60_000 -> :ok
      end

      if is_binary(marker_path) do
        :ok = File.write(marker_path, "complete:#{execution_id}\n")
      end

      %Outcome{status: :success, context_updates: %{"probe.multi" => node.id}}
    end
  end

  defmodule CompleteThenBlockProbe do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      counter = opts[:invoke_counter]
      parent = opts[:parent]
      execution_id = opts[:execution_id]
      marker_path = opts[:effect_marker_path]

      if counter,
        do: InvokeCounter.record(counter, %{node_id: node.id, execution_id: execution_id})

      # External effect fully completed before handler return / receipt.
      if is_binary(marker_path) do
        :ok = File.write(marker_path, "effect_done:#{execution_id}\n")
      end

      if parent do
        send(parent, {:l4_effect_done, node.id, execution_id, marker_path})
      end

      receive do
        :l4_must_not_continue -> :ok
      after
        60_000 -> :ok
      end

      %Outcome{status: :success, context_updates: %{"probe.done" => node.id}}
    end
  end

  setup do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    :ok = Registry.register("l4_side", SideEffectProbe)
    :ok = Registry.register("l4_multi", MultiStepProbe)
    :ok = Registry.register("l4_block", CompleteThenBlockProbe)

    suffix = System.unique_integer([:positive, :monotonic])
    counter_name = :"l4_counter_#{suffix}"
    {:ok, _counter} = start_supervised({InvokeCounter, counter_name})

    on_exit(fn -> Registry.restore_custom_handlers(saved) end)

    %{invoke_counter: counter_name}
  end

  # ---------------------------------------------------------------------------
  # 1. Kill after durable pending prepare, before external effect
  # ---------------------------------------------------------------------------

  describe "L4A kill after durable pending prepare" do
    test "process death leaves pending effect; recovery never invokes handler", ctx do
      harness = start_hold_journal("l4_prep", :prepare, self())
      jopts = [server: harness.journal_name]
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l4_prep")
      parent = self()
      counter = ctx.invoke_counter

      {engine_pid, mon} =
        spawn_engine_run(parse!(side_dot()),
          run_id: harness.run_id,
          logs_root: logs_root,
          journal_opts: jopts,
          parent: parent,
          identity_private_key: identity,
          resumable: true,
          invoke_counter: counter
        )

      assert_receive {:store_held, :prepare, held}, 5_000
      assert is_map(held.effect)
      assert held.effect["status"] == "pending"
      exec_id = held.effect["execution_id"]
      assert is_binary(exec_id)

      # Handler must not have run: Engine is blocked on prepare reply.
      assert InvokeCounter.count(counter) == 0
      refute_receive {:l4_probe, _, _}, 50

      kill_engine!(engine_pid, mon)

      assert :ok = HoldStore.release(harness.store_name)
      await_effect!(harness.run_id, jopts, "pending", exec_id)

      rec = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec.current_effect["status"] == "pending"
      assert rec.current_effect["execution_id"] == exec_id
      assert rec.current_effect["node_id"] == "task"
      refute "task" in (rec.completed_nodes || [])

      assert InvokeCounter.count(counter) == 0

      # Public resume via default journal: never reinvokes.
      {logs_root, dot_path, graph_hash} =
        publish_interrupted_for_public_resume!(
          harness.run_id,
          jopts,
          logs_root,
          side_dot(),
          "l4_prep"
        )

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Orchestrator.resume(harness.run_id,
                 parent: parent,
                 identity_private_key: identity,
                 invoke_counter: counter
               )

      assert InvokeCounter.count(counter) == 0
      refute_receive {:l4_probe, _, _}, 150

      final = PipelineStatus.get_record(harness.run_id)
      assert final.current_effect["status"] == "pending"
      assert final.current_effect["execution_id"] == exec_id
      refute final.status == :completed
      refute final.status == :failed

      # Silence unused for clarity (path retained for resume auth).
      assert is_binary(dot_path) and is_binary(graph_hash) and is_binary(logs_root)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Kill during multi-step effect after partial external progress
  # ---------------------------------------------------------------------------

  describe "L4A kill during multi-step effect after partial progress" do
    test "pending/indeterminate evidence and zero replay", ctx do
      harness = start_isolated_journal("l4_multi")
      jopts = [server: harness.journal_name]
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l4_multi")
      marker_path = tmp_marker("l4_multi")
      parent = self()
      counter = ctx.invoke_counter

      {engine_pid, mon} =
        spawn_engine_run(parse!(multi_dot()),
          run_id: harness.run_id,
          logs_root: logs_root,
          journal_opts: jopts,
          parent: parent,
          identity_private_key: identity,
          resumable: true,
          invoke_counter: counter,
          effect_marker_path: marker_path
        )

      assert_receive {:l4_partial, "task", exec_id, ^marker_path}, 5_000
      assert is_binary(exec_id)
      assert File.read!(marker_path) == "partial:#{exec_id}\n"
      assert InvokeCounter.count(counter) == 1

      rec_mid = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec_mid.current_effect["status"] == "pending"
      assert rec_mid.current_effect["execution_id"] == exec_id

      kill_engine!(engine_pid, mon)

      # Partial progress remains; effect never completed.
      assert File.read!(marker_path) == "partial:#{exec_id}\n"
      rec = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec.current_effect["status"] == "pending"
      assert rec.current_effect["execution_id"] == exec_id
      refute rec.current_effect["status"] == "completed"
      refute rec.current_effect["status"] == "settled"

      reopen_as_recovering!(harness.run_id, jopts, logs_root)

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Engine.run(parse!(multi_dot()),
                 run_id: harness.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true,
                 force_replay: true,
                 invoke_counter: counter,
                 effect_marker_path: marker_path
               )

      assert InvokeCounter.count(counter) == 1
      refute_receive {:l4_partial, _, _, _}, 150
      refute_receive {:l4_probe, _, _}, 50
      assert File.read!(marker_path) == "partial:#{exec_id}\n"

      rec2 = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec2.current_effect["status"] == "pending"
      assert rec2.current_effect["execution_id"] == exec_id
      refute rec2.status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Kill after external effect completes, before handler return / receipt
  # ---------------------------------------------------------------------------

  describe "L4A kill after effect completes before receipt" do
    test "pending/indeterminate evidence and zero replay", ctx do
      harness = start_isolated_journal("l4_pre_rcpt")
      jopts = [server: harness.journal_name]
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l4_pre_rcpt")
      marker_path = tmp_marker("l4_pre_rcpt")
      parent = self()
      counter = ctx.invoke_counter

      {engine_pid, mon} =
        spawn_engine_run(parse!(block_dot()),
          run_id: harness.run_id,
          logs_root: logs_root,
          journal_opts: jopts,
          parent: parent,
          identity_private_key: identity,
          resumable: true,
          invoke_counter: counter,
          effect_marker_path: marker_path
        )

      assert_receive {:l4_effect_done, "task", exec_id, ^marker_path}, 5_000
      assert is_binary(exec_id)
      assert File.read!(marker_path) == "effect_done:#{exec_id}\n"
      assert InvokeCounter.count(counter) == 1

      rec_mid = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec_mid.current_effect["status"] == "pending"
      assert rec_mid.current_effect["execution_id"] == exec_id

      kill_engine!(engine_pid, mon)

      # External effect completed, but durable receipt was never recorded.
      rec = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec.current_effect["status"] == "pending"
      assert rec.current_effect["execution_id"] == exec_id
      refute is_binary(rec.current_effect["result_digest"])

      reopen_as_recovering!(harness.run_id, jopts, logs_root)

      assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
               Engine.run(parse!(block_dot()),
                 run_id: harness.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true,
                 force_replay: true,
                 invoke_counter: counter,
                 effect_marker_path: marker_path
               )

      assert InvokeCounter.count(counter) == 1
      refute_receive {:l4_effect_done, _, _, _}, 150

      rec2 = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec2.current_effect["status"] == "pending"
      assert rec2.current_effect["execution_id"] == exec_id
      refute rec2.status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Kill after completed receipt durable (and checkpoint applied) before
  #    progress settle / graph advance — exact reconciliation, zero reinvoke
  # ---------------------------------------------------------------------------

  describe "L4A kill after completed receipt before progress/settle/advance" do
    test "completed evidence reconciles and settles without handler reinvocation", ctx do
      # Hold the completed-progress journal write: receipt is already durable
      # and Checkpoint.persist has already bound the visit marker. Process death
      # before settle/graph advance; resume exact-reconciles without replaying.
      harness = start_hold_journal("l4_rcpt", :completed_progress, self())
      jopts = [server: harness.journal_name]
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l4_rcpt")
      parent = self()
      counter = ctx.invoke_counter

      {engine_pid, mon} =
        spawn_engine_run(parse!(side_dot()),
          run_id: harness.run_id,
          logs_root: logs_root,
          journal_opts: jopts,
          parent: parent,
          identity_private_key: identity,
          resumable: true,
          invoke_counter: counter
        )

      assert_receive {:l4_probe, "task", exec_id}, 5_000
      assert is_binary(exec_id)
      assert InvokeCounter.count(counter) == 1

      assert_receive {:store_held, :completed_progress, held}, 5_000
      assert held.effect["status"] == "completed"
      assert held.effect["execution_id"] == exec_id
      assert "task" in held.completed_nodes

      # Checkpoint must already exist for exact visit reconciliation.
      assert File.exists?(Path.join(logs_root, "checkpoint.json"))

      assert {:ok, checkpoint} =
               Arbor.Orchestrator.Engine.Checkpoint.load(
                 Path.join(logs_root, "checkpoint.json"),
                 run_id: harness.run_id,
                 hmac_secret: Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
               )

      assert checkpoint.execution_digests["task"].execution_id == exec_id

      kill_engine!(engine_pid, mon)

      assert :ok = HoldStore.release(harness.store_name)
      await_effect!(harness.run_id, jopts, "completed", exec_id)

      rec = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id
      assert is_binary(rec.current_effect["result_digest"])
      assert "task" in (rec.completed_nodes || [])
      refute "exit" in (rec.completed_nodes || [])
      refute rec.current_effect["status"] == "settled"

      # Public resume: exact reconciliation + settle, zero reinvocation.
      _published =
        publish_interrupted_for_public_resume!(
          harness.run_id,
          jopts,
          logs_root,
          side_dot(),
          "l4_rcpt"
        )

      assert {:ok, result} =
               Orchestrator.resume(harness.run_id,
                 parent: parent,
                 identity_private_key: identity,
                 invoke_counter: counter
               )

      assert InvokeCounter.count(counter) == 1
      refute_receive {:l4_probe, "task", _}, 150
      assert result.completed_nodes == ["start", "task", "exit"]

      final = PipelineStatus.get_record(harness.run_id)
      assert final.status == :completed
      assert final.current_effect["status"] == "settled"
      assert final.current_effect["execution_id"] == exec_id
      assert final.completed_nodes == ["start", "task", "exit"]
    end

    test "receipt-only death (before checkpoint) stays completed-unapplied, no replay", ctx do
      # Stricter pre-checkpoint window: durable completed receipt held before
      # Checkpoint.persist / progress. Recovery must not reinvoke.
      harness = start_hold_journal("l4_rcpt_only", :receipt, self())
      jopts = [server: harness.journal_name]
      identity = :crypto.strong_rand_bytes(32)
      logs_root = tmp_logs("l4_rcpt_only")
      parent = self()
      counter = ctx.invoke_counter

      {engine_pid, mon} =
        spawn_engine_run(parse!(side_dot()),
          run_id: harness.run_id,
          logs_root: logs_root,
          journal_opts: jopts,
          parent: parent,
          identity_private_key: identity,
          resumable: true,
          invoke_counter: counter
        )

      assert_receive {:l4_probe, "task", exec_id}, 5_000
      assert_receive {:store_held, :receipt, held}, 5_000
      assert held.effect["status"] == "completed"
      assert held.effect["execution_id"] == exec_id
      refute "task" in held.completed_nodes

      kill_engine!(engine_pid, mon)

      assert :ok = HoldStore.release(harness.store_name)
      await_effect!(harness.run_id, jopts, "completed", exec_id)

      rec = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec.current_effect["status"] == "completed"
      assert rec.current_effect["execution_id"] == exec_id
      assert is_binary(rec.current_effect["result_digest"])

      # Seed only pre-task checkpoint so resume authenticates without this visit.
      seed_start_checkpoint!(logs_root, harness.run_id, identity)
      reopen_as_recovering!(harness.run_id, jopts, logs_root)

      assert {:error, {:completed_effect_unapplied, "task", ^exec_id}} =
               Engine.run(parse!(side_dot()),
                 run_id: harness.run_id,
                 logs_root: logs_root,
                 journal_opts: jopts,
                 parent: parent,
                 identity_private_key: identity,
                 resume: true,
                 recovery: true,
                 force_replay: true,
                 invoke_counter: counter
               )

      assert InvokeCounter.count(counter) == 1
      refute_receive {:l4_probe, "task", _}, 150

      rec2 = PipelineStatus.get_record(harness.run_id, jopts)
      assert rec2.current_effect["status"] == "completed"
      assert rec2.current_effect["execution_id"] == exec_id
      refute rec2.status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_engine_run(graph, opts) do
    test = self()

    spawn_monitor(fn ->
      result =
        try do
          Engine.run(graph, opts)
        catch
          kind, reason ->
            {:engine_crash, kind, reason, __STACKTRACE__}
        end

      send(test, {:engine_finished, self(), result})
    end)
  end

  defp kill_engine!(pid, mon) when is_pid(pid) and is_reference(mon) do
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^mon, :process, ^pid, :killed}, 2_000
    refute Process.alive?(pid)

    # Drain any late finished message without treating it as success.
    receive do
      {:engine_finished, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp start_isolated_journal(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    run_id = "#{label}_run_#{suffix}"

    {:ok, journal} =
      start_supervised({RunJournal, name: journal_name, ets_table: ets_table})

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id, server: journal_name)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{journal_name: journal_name, ets_table: ets_table, run_id: run_id, journal: journal}
  end

  defp start_hold_journal(label, hold_on, parent, opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    store_name = :"#{label}_store_#{suffix}"
    run_id = "#{label}_run_#{suffix}"
    hold_node = Keyword.get(opts, :hold_node, "task")

    {:ok, _store} =
      start_supervised(
        {HoldStore, name: store_name, hold_on: hold_on, parent: parent, hold_node: hold_node}
      )

    {:ok, journal} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: HoldStore,
         store_name: store_name,
         start_store: false}
      )

    on_exit(fn ->
      # Best-effort release so a failed test does not strand RunJournal forever.
      try do
        _ = HoldStore.release(store_name)
      catch
        :exit, _ -> :ok
      end

      try do
        _ = PipelineStatus.delete(run_id, server: journal_name)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      journal_name: journal_name,
      ets_table: ets_table,
      store_name: store_name,
      run_id: run_id,
      journal: journal
    }
  end

  defp await_effect!(run_id, jopts, status, exec_id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_effect_loop(run_id, jopts, status, exec_id, deadline)
  end

  defp await_effect_loop(run_id, jopts, status, exec_id, deadline) do
    rec = PipelineStatus.get_record(run_id, jopts)
    effect = rec && rec.current_effect

    cond do
      is_map(effect) and effect["status"] == status and effect["execution_id"] == exec_id ->
        rec

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "timed out waiting for effect status=#{inspect(status)} exec=#{inspect(exec_id)}; got=#{inspect(effect)}"
        )

      true ->
        Process.sleep(10)
        await_effect_loop(run_id, jopts, status, exec_id, deadline)
    end
  end

  defp reopen_as_recovering!(run_id, jopts, logs_root) do
    rec = PipelineStatus.get_record(run_id, jopts)
    assert %Record{} = rec

    reopened = %Record{
      rec
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: logs_root || rec.logs_root
    }

    assert :ok = PipelineStatus.put(reopened, jopts)
    assert {:ok, _} = PipelineStatus.claim_for_recovery_record(run_id, node(), jopts)
  end

  defp publish_interrupted_for_public_resume!(run_id, jopts, logs_root, dot, label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_l4_dot_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    :ok = File.mkdir_p(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "pipeline.dot")
    :ok = File.write(path, dot)
    hash = :crypto.hash(:sha256, dot) |> Base.encode16(case: :lower)

    rec = PipelineStatus.get_record(run_id, jopts)
    assert %Record{} = rec

    reopened = %Record{
      rec
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: logs_root,
        dot_source_path: path,
        graph_hash: hash
    }

    assert :ok = PipelineStatus.put(reopened)

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {logs_root, path, hash}
  end

  defp seed_start_checkpoint!(logs_root, run_id, identity) do
    alias Arbor.Orchestrator.Engine.Checkpoint
    alias Arbor.Orchestrator.Engine.Context

    context = Context.new(%{"outcome" => "success"})
    outcomes = %{"start" => %Outcome{status: :success}}

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    _ = File.rm_rf(Path.join(logs_root, "checkpoint.json"))
    :ok = File.mkdir_p(logs_root)

    checkpoint =
      Checkpoint.from_state("start", ["start"], %{}, context, outcomes,
        run_id: run_id,
        pipeline_started_at: DateTime.utc_now(),
        execution_digests: %{}
      )

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, hmac_secret: hmac)
  end

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_l4_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp tmp_marker(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_l4_marker_#{label}_#{System.unique_integer([:positive, :monotonic])}.txt"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp side_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l4_side"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp multi_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l4_multi"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp block_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="l4_block"]
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
