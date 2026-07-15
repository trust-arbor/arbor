defmodule Arbor.Shell.AppleContainerUnitDrainCoordinatorTest do
  @moduledoc """
  Focused durable drain-coordinator reconstruction and start-admission tests.

  Uses closed same-library test-only seams via start_for_test/1 — never wires
  Application/test_helper and never weakens Journal/Reconciler/Worker authority.
  Coordinators are unregistered and addressed by PID (no dynamic atom names).
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.AppleContainerUnitDrainCoordinator, as: Coordinator

  @moduletag :fast

  @hex32 String.duplicate("a", 32)
  @unit_name "arbor-v1-#{@hex32}"
  @token String.duplicate("b", 64)
  @execution_id "exec-coord-1"
  @reserved_at_ms 1_700_000_000_000
  @timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Shared suite-stable fakes (one process each for the module, not per-test atoms)
  # ---------------------------------------------------------------------------

  defmodule SharedTrace do
    @moduledoc false
    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset do
      ensure_started()
      GenServer.call(__MODULE__, :reset)
    end

    def append(event) do
      ensure_started()
      GenServer.call(__MODULE__, {:append, event})
    end

    def events do
      ensure_started()
      GenServer.call(__MODULE__, :events)
    end

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_call(:reset, _from, _), do: {:reply, :ok, []}
    def handle_call({:append, event}, _from, events), do: {:reply, :ok, [event | events]}
    def handle_call(:events, _from, events), do: {:reply, Enum.reverse(events), events}
  end

  defmodule FakeClock do
    @moduledoc false
    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, 1_000_000, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(ms \\ 1_000_000) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, ms})
    end

    def monotonic_ms do
      ensure_started()
      GenServer.call(__MODULE__, :monotonic_ms)
    end

    @impl true
    def init(ms), do: {:ok, ms}

    @impl true
    def handle_call({:reset, ms}, _from, _), do: {:reply, :ok, ms}

    def handle_call(:monotonic_ms, _from, ms) do
      SharedTrace.append(:clock_monotonic)
      {:reply, ms, ms}
    end
  end

  defmodule FakeJournal do
    @moduledoc false
    use GenServer

    @token String.duplicate("b", 64)
    @reserved_at_ms 1_700_000_000_000

    def ensure_started do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(opts \\ []) when is_list(opts) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, opts})
    end

    def recovery_entries(server \\ __MODULE__),
      do: GenServer.call(server, :recovery_entries)

    def reserve_record(unit_name, execution_id, server \\ __MODULE__),
      do: GenServer.call(server, {:reserve_record, unit_name, execution_id})

    def complete(unit_name, token, server \\ __MODULE__),
      do: GenServer.call(server, {:complete, unit_name, token})

    def events do
      ensure_started()
      GenServer.call(__MODULE__, :events)
    end

    def load_count do
      ensure_started()
      GenServer.call(__MODULE__, :load_count)
    end

    def set_entries(entries) when is_list(entries) do
      ensure_started()
      GenServer.call(__MODULE__, {:set_entries, entries})
    end

    @impl true
    def init(_) do
      {:ok,
       %{
         entries: [],
         recovery_result: :entries,
         complete_result: :ok,
         events: [],
         load_count: 0,
         reserve_fail: false
       }}
    end

    @impl true
    def handle_call({:reset, opts}, _from, _state) do
      {:reply, :ok,
       %{
         entries: Keyword.get(opts, :entries, []),
         recovery_result: Keyword.get(opts, :recovery_result, :entries),
         complete_result: Keyword.get(opts, :complete_result, :ok),
         events: [],
         load_count: 0,
         reserve_fail: Keyword.get(opts, :reserve_fail, false)
       }}
    end

    def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}
    def handle_call(:load_count, _from, state), do: {:reply, state.load_count, state}

    def handle_call({:set_entries, entries}, _from, state) do
      {:reply, :ok, %{state | entries: entries, recovery_result: :entries}}
    end

    def handle_call(:recovery_entries, _from, state) do
      state = %{
        state
        | load_count: state.load_count + 1,
          events: [:recovery_entries | state.events]
      }

      reply =
        case state.recovery_result do
          :entries -> {:ok, state.entries}
          {:error, _} = err -> err
          other when is_tuple(other) -> other
        end

      {:reply, reply, state}
    end

    def handle_call({:reserve_record, unit_name, execution_id}, _from, state) do
      SharedTrace.append({:journal_reserve, unit_name, execution_id})
      events = [{:reserve_record, unit_name, execution_id} | state.events]

      if state.reserve_fail do
        {:reply, {:error, :journal_reserve_failed}, %{state | events: events}}
      else
        record = %{
          unit_name: unit_name,
          execution_id: execution_id,
          token: @token,
          reserved_at_ms: @reserved_at_ms
        }

        entries = [record | Enum.reject(state.entries, &(&1.unit_name == unit_name))]
        {:reply, {:ok, record}, %{state | entries: entries, events: events}}
      end
    end

    def handle_call({:complete, unit_name, token}, _from, state) do
      events = [{:complete, unit_name, token} | state.events]

      case state.complete_result do
        :ok ->
          entries =
            Enum.reject(state.entries, fn e ->
              e.unit_name == unit_name and e.token == token
            end)

          {:reply, :ok, %{state | entries: entries, events: events}}

        {:error, _} = err ->
          {:reply, err, %{state | events: events}}
      end
    end
  end

  defmodule FakeReconciler do
    @moduledoc false
    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(opts \\ []) when is_list(opts) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, opts})
    end

    def status(server \\ __MODULE__), do: GenServer.call(server, :status)

    def recover_entry(record, receipt_ref, server \\ __MODULE__),
      do: GenServer.call(server, {:recover_entry, record, receipt_ref})

    def recover_all(receipt_ref, server \\ __MODULE__),
      do: GenServer.call(server, {:recover_all, receipt_ref})

    def set_phase(phase) when is_binary(phase) do
      ensure_started()
      GenServer.call(__MODULE__, {:set_phase, phase})
    end

    def set_recover_result(result) do
      ensure_started()
      GenServer.call(__MODULE__, {:set_recover_result, result})
    end

    def set_recover_all_mode(mode) do
      ensure_started()
      GenServer.call(__MODULE__, {:set_recover_all_mode, mode})
    end

    def emit_recover_all(receipt_ref, caller \\ nil) do
      ensure_started()
      GenServer.call(__MODULE__, {:emit_recover_all, receipt_ref, caller})
    end

    def events do
      ensure_started()
      GenServer.call(__MODULE__, :events)
    end

    def status_count do
      ensure_started()
      GenServer.call(__MODULE__, :status_count)
    end

    def pending do
      ensure_started()
      GenServer.call(__MODULE__, :pending)
    end

    def recover_all_pending do
      ensure_started()
      GenServer.call(__MODULE__, :recover_all_pending)
    end

    @impl true
    def init(_) do
      {:ok,
       %{
         phase: "ready",
         events: [],
         pending: %{},
         recover_all_pending: %{},
         status_count: 0,
         recover_result: :ok,
         recover_all_mode: :auto_complete
       }}
    end

    @impl true
    def handle_call({:reset, opts}, _from, _state) do
      {:reply, :ok,
       %{
         phase: Keyword.get(opts, :phase, "ready"),
         events: [],
         pending: %{},
         recover_all_pending: %{},
         status_count: 0,
         recover_result: Keyword.get(opts, :recover_result, :ok),
         recover_all_mode: Keyword.get(opts, :recover_all_mode, :auto_complete)
       }}
    end

    def handle_call(:status, _from, state) do
      {:reply, %{"phase" => state.phase, "worker_count" => 0},
       %{state | status_count: state.status_count + 1}}
    end

    def handle_call(:status_count, _from, state), do: {:reply, state.status_count, state}
    def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}
    def handle_call(:pending, _from, state), do: {:reply, state.pending, state}

    def handle_call(:recover_all_pending, _from, state),
      do: {:reply, state.recover_all_pending, state}

    def handle_call({:set_phase, phase}, _from, state), do: {:reply, :ok, %{state | phase: phase}}

    def handle_call({:set_recover_result, result}, _from, state),
      do: {:reply, :ok, %{state | recover_result: result}}

    def handle_call({:set_recover_all_mode, mode}, _from, state),
      do: {:reply, :ok, %{state | recover_all_mode: mode}}

    def handle_call({:recover_entry, record, receipt_ref}, {caller, _}, state) do
      events = [{:recover_entry, record, receipt_ref, caller} | state.events]

      case state.recover_result do
        :ok ->
          pending = Map.put(state.pending, receipt_ref, {record, caller})
          {:reply, :ok, %{state | events: events, pending: pending}}

        {:error, _reason} = error ->
          {:reply, error, %{state | events: events}}
      end
    end

    def handle_call({:recover_all, receipt_ref}, {caller, _}, state) do
      events = [{:recover_all, receipt_ref, caller, self()} | state.events]

      cond do
        state.phase != "ready" ->
          {:reply, {:error, :reconciler_not_ready}, %{state | events: events}}

        match?({:error, _}, state.recover_result) ->
          {:reply, state.recover_result, %{state | events: events}}

        state.recover_all_mode == :auto_complete ->
          # Simulate authoritative sweep: clear journal rows then notify.
          _ = FakeJournal.set_entries([])
          send(caller, {:apple_container_unit_recovery_all_complete, self(), receipt_ref})
          {:reply, :ok, %{state | events: events}}

        state.recover_all_mode == :hold ->
          pending = Map.put(state.recover_all_pending, receipt_ref, caller)
          {:reply, :ok, %{state | events: events, recover_all_pending: pending}}

        state.recover_all_mode == :reject ->
          {:reply, {:error, :recovery_temporarily_unavailable}, %{state | events: events}}

        true ->
          {:reply, {:error, :recovery_temporarily_unavailable}, %{state | events: events}}
      end
    end

    def handle_call({:emit_recover_all, receipt_ref, caller_opt}, _from, state) do
      case Map.get(state.recover_all_pending, receipt_ref) do
        caller when is_pid(caller) ->
          target = if is_pid(caller_opt), do: caller_opt, else: caller
          send(target, {:apple_container_unit_recovery_all_complete, self(), receipt_ref})
          pending = Map.delete(state.recover_all_pending, receipt_ref)
          {:reply, :ok, %{state | recover_all_pending: pending}}

        _missing ->
          {:reply, {:error, :no_pending}, state}
      end
    end
  end

  defmodule FakeWorker do
    @moduledoc false
    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(opts \\ []) when is_list(opts) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, opts})
    end

    def register_worker(pid, opts) when is_pid(pid) and is_list(opts) do
      ensure_started()
      GenServer.call(__MODULE__, {:register, pid, opts})
    end

    def ownership_hint(worker, _timeout \\ 5_000) do
      ensure_started()
      GenServer.call(__MODULE__, {:ownership_hint, worker, self()})
    end

    def ownership_info(worker, exact_record, _timeout \\ 5_000) do
      ensure_started()
      GenServer.call(__MODULE__, {:ownership_info, worker, exact_record, self()})
    end

    def request_drain(worker, receipt_ref, _timeout \\ 5_000) do
      ensure_started()
      GenServer.call(__MODULE__, {:request_drain, worker, receipt_ref, self()})
    end

    def start_under_coordinator_durable(
          spec,
          executable,
          execution_id,
          start_ref,
          controller_pid,
          journal_record,
          operation_deadline
        ) do
      ensure_started()

      GenServer.call(
        __MODULE__,
        {:start_durable, spec, executable, execution_id, start_ref, controller_pid,
         journal_record, operation_deadline}
      )
    end

    def events do
      ensure_started()
      GenServer.call(__MODULE__, :events)
    end

    def drain_pending do
      ensure_started()
      GenServer.call(__MODULE__, :drain_pending)
    end

    def emit_drain(worker, execution_id, receipt_ref) do
      ensure_started()
      GenServer.call(__MODULE__, {:emit_drain, worker, execution_id, receipt_ref})
    end

    def set_start_result(result) do
      ensure_started()
      GenServer.call(__MODULE__, {:set_start_result, result})
    end

    @impl true
    def init(_) do
      {:ok, %{workers: %{}, events: [], drain_pending: %{}, start_result: :spawn_worker}}
    end

    @impl true
    def handle_call({:reset, opts}, _from, _state) do
      {:reply, :ok,
       %{
         workers: %{},
         events: [],
         drain_pending: %{},
         start_result: Keyword.get(opts, :start_result, :spawn_worker)
       }}
    end

    def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}
    def handle_call(:drain_pending, _from, state), do: {:reply, state.drain_pending, state}

    def handle_call({:set_start_result, result}, _from, state) do
      {:reply, :ok, %{state | start_result: result}}
    end

    def handle_call({:register, pid, opts}, _from, state) do
      meta = %{
        execution_id: Keyword.fetch!(opts, :execution_id),
        journal_record: Keyword.get(opts, :journal_record),
        owner: Keyword.get(opts, :owner),
        deny_hint: Keyword.get(opts, :deny_hint, false),
        deny_info: Keyword.get(opts, :deny_info, false)
      }

      {:reply, :ok, %{state | workers: Map.put(state.workers, pid, meta)}}
    end

    def handle_call({:ownership_hint, worker, caller}, _from, state) do
      events = [{:ownership_hint, worker, caller} | state.events]

      reply =
        case Map.get(state.workers, worker) do
          %{deny_hint: true} ->
            {:error, :ownership_denied}

          %{execution_id: exec, owner: owner} ->
            if is_nil(owner) or owner == caller do
              {:ok, %{execution_id: exec}}
            else
              {:error, :ownership_denied}
            end

          nil ->
            {:error, :ownership_denied}
        end

      {:reply, reply, %{state | events: events}}
    end

    def handle_call({:ownership_info, worker, exact_record, caller}, _from, state) do
      events = [{:ownership_info, worker, exact_record, caller} | state.events]

      reply =
        case Map.get(state.workers, worker) do
          %{deny_info: true} ->
            {:error, :ownership_denied}

          %{journal_record: stored, execution_id: exec, owner: owner} when is_map(stored) ->
            if (is_nil(owner) or owner == caller) and stored == exact_record do
              {:ok,
               %{
                 journal_record: stored,
                 controller_pid: self(),
                 execution_id: exec
               }}
            else
              {:error, :ownership_denied}
            end

          _ ->
            {:error, :ownership_denied}
        end

      {:reply, reply, %{state | events: events}}
    end

    def handle_call({:request_drain, worker, receipt_ref, caller}, _from, state) do
      events = [{:request_drain, worker, receipt_ref, caller} | state.events]
      pending = Map.put(state.drain_pending, worker, {receipt_ref, caller})
      {:reply, :ok, %{state | events: events, drain_pending: pending}}
    end

    def handle_call({:emit_drain, worker, execution_id, receipt_ref}, _from, state) do
      case Map.get(state.drain_pending, worker) do
        {^receipt_ref, caller} ->
          send(caller, {:apple_container_unit_drained, worker, execution_id, receipt_ref})
          {:reply, :ok, state}

        _other ->
          {:reply, {:error, :no_pending}, state}
      end
    end

    def handle_call(
          {:start_durable, spec, executable, execution_id, start_ref, controller_pid, record,
           deadline},
          _from,
          state
        ) do
      SharedTrace.append({:worker_start, execution_id, deadline})

      events = [
        {:start_durable, spec, executable, execution_id, start_ref, controller_pid, record,
         deadline}
        | state.events
      ]

      case state.start_result do
        :spawn_worker ->
          worker = spawn(fn -> Process.sleep(:infinity) end)

          meta = %{
            execution_id: execution_id,
            journal_record: record,
            owner: nil,
            deny_hint: false,
            deny_info: false
          }

          {:reply, {:ok, worker},
           %{state | events: events, workers: Map.put(state.workers, worker, meta)}}

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | events: events}}

        {:ok, pid} when is_pid(pid) ->
          {:reply, {:ok, pid}, %{state | events: events}}
      end
    end
  end

  defmodule Snapshot do
    @moduledoc false
    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, {:ok, []}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(result \\ {:ok, []}) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, result})
    end

    def set(result) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, result})
    end

    def snapshot do
      ensure_started()
      GenServer.call(__MODULE__, :snapshot)
    end

    def load_count do
      ensure_started()
      GenServer.call(__MODULE__, :load_count)
    end

    @impl true
    def init(result), do: {:ok, %{result: result, load_count: 0}}

    @impl true
    def handle_call({:reset, result}, _from, _state),
      do: {:reply, :ok, %{result: result, load_count: 0}}

    def handle_call(:snapshot, _from, state) do
      {:reply, state.result, %{state | load_count: state.load_count + 1}}
    end

    def handle_call(:load_count, _from, state), do: {:reply, state.load_count, state}
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    SharedTrace.ensure_started()
    FakeClock.ensure_started()
    FakeJournal.ensure_started()
    FakeReconciler.ensure_started()
    FakeWorker.ensure_started()
    Snapshot.ensure_started()

    :ok = SharedTrace.reset()
    :ok = FakeClock.reset()
    :ok = FakeJournal.reset()
    :ok = FakeReconciler.reset()
    :ok = FakeWorker.reset()
    :ok = Snapshot.reset({:ok, []})

    {:ok, coordinator_holder} = Agent.start(fn -> nil end)

    on_exit(fn ->
      pid =
        if Process.alive?(coordinator_holder) do
          Agent.get(coordinator_holder, & &1)
        end

      if is_pid(pid), do: stop_pid(pid)

      if Process.alive?(coordinator_holder) do
        Agent.stop(coordinator_holder)
      end
    end)

    {:ok, holder: coordinator_holder}
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    else
      :ok
    end
  end

  defp record(opts \\ []) do
    %{
      unit_name: Keyword.get(opts, :unit_name, @unit_name),
      execution_id: Keyword.get(opts, :execution_id, @execution_id),
      token: Keyword.get(opts, :token, @token),
      reserved_at_ms: Keyword.get(opts, :reserved_at_ms, @reserved_at_ms)
    }
  end

  defp start_coord!(holder, opts \\ []) do
    base = [
      journal: FakeJournal,
      journal_server: FakeJournal,
      reconciler: FakeReconciler,
      reconciler_server: FakeReconciler,
      unit_supervisor: :unused_supervisor,
      worker_module: FakeWorker,
      clock: FakeClock,
      snapshot_workers: &Snapshot.snapshot/0,
      reconstruct_retry_ms: 30,
      ownership_call_timeout_ms: 1_000,
      drain_handshake_timeout_ms: 1_000
    ]

    assert {:ok, pid} = Coordinator.start_for_test(Keyword.merge(base, opts))
    :ok = Agent.update(holder, fn _ -> pid end)
    pid
  end

  defp await_ready(pid, timeout \\ 2_000) when is_pid(pid) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if Process.alive?(pid) do
        state = :sys.get_state(pid)

        if state.phase == :ready do
          :ready
        else
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            :retry
          else
            flunk("coordinator did not become ready: phase=#{inspect(state.phase)}")
          end
        end
      else
        flunk("coordinator died")
      end
    end)
    |> Enum.find(&(&1 == :ready))
  end

  defp await_phase(pid, phase, timeout \\ 2_000) when is_pid(pid) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if Process.alive?(pid) do
        state = :sys.get_state(pid)

        if state.phase == phase do
          :ok
        else
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            :retry
          else
            flunk("expected phase #{inspect(phase)}, got #{inspect(state.phase)}")
          end
        end
      else
        flunk("coordinator died")
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp spec_fixture do
    %{
      plan: %{unit_name: @unit_name},
      timeout_ms: @timeout_ms,
      max_output_bytes: 8_192
    }
  end

  defp eventually!(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          :retry
        else
          flunk("condition not met within #{timeout}ms")
        end
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  # ---------------------------------------------------------------------------
  # Closed admission while reconstructing
  # ---------------------------------------------------------------------------

  describe "closed reconstruction prerequisites" do
    test "missing unit supervisor stays reconstructing and rejects start", %{holder: holder} do
      :ok = Snapshot.set({:error, :unit_supervisor_unavailable})
      :ok = FakeReconciler.reset(phase: "ready")
      :ok = FakeJournal.reset(entries: [])

      pid = start_coord!(holder)
      Process.sleep(80)

      assert :sys.get_state(pid).phase == :reconstructing

      assert {:error, :unit_start_unavailable} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :exec, @execution_id, make_ref()}
               )
    end

    test "journal unavailability is not an empty ready snapshot", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready")
      :ok = FakeJournal.reset(recovery_result: {:error, :apple_container_unit_journal_disabled})

      pid = start_coord!(holder)
      Process.sleep(80)

      assert :sys.get_state(pid).phase == :reconstructing

      assert {:error, :unit_start_unavailable} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :exec, @execution_id, make_ref()}
               )
    end

    test "reconciler not ready keeps admission closed", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "unavailable")
      :ok = FakeJournal.reset(entries: [])

      pid = start_coord!(holder)
      Process.sleep(80)
      assert :sys.get_state(pid).phase == :reconstructing

      :ok = FakeReconciler.set_phase("ready")
      await_ready(pid)
      assert :sys.get_state(pid).phase == :ready
    end
  end

  describe "ownership verification before adoption" do
    test "hint match plus ownership_info denial does not adopt or open admission", %{
      holder: holder
    } do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec,
          deny_info: true
        )

      pid = start_coord!(holder)
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.phase == :reconstructing
      assert map_size(state.monitored) == 0

      assert {:error, :unit_start_unavailable} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :exec, @execution_id, make_ref()}
               )

      events = FakeWorker.events()
      assert Enum.any?(events, &match?({:request_drain, ^worker, _, _}, &1))
      assert Enum.any?(events, &match?({:ownership_info, ^worker, ^rec, _}, &1))
    end

    test "exact candidate reconstruction reaches ready and is monitored", %{holder: holder} do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      state = :sys.get_state(pid)
      assert state.phase == :ready
      assert map_size(state.monitored) == 1

      [{_mon, meta}] = Map.to_list(state.monitored)
      assert meta.worker_pid == worker
      assert meta.journal_record == rec
      assert meta.execution_id == @execution_id
    end
  end

  describe "orphan recovery and unmatched drain re-reads" do
    test "orphan recovery requires a fresh authoritative reread; forged receipts do not settle",
         %{holder: holder} do
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready")

      # Keep the legitimate periodic reread outside the forged-message
      # observation window so any load increase is attributable to the message.
      pid = start_coord!(holder, reconstruct_retry_ms: 500)
      Process.sleep(80)

      assert :sys.get_state(pid).phase == :reconstructing
      assert FakeReconciler.events() != []

      journal_loads = FakeJournal.load_count()
      status_loads = FakeReconciler.status_count()
      snap_loads = Snapshot.load_count()

      # Forged recovery receipt must not wake reconstruction or open admission.
      send(
        pid,
        {:apple_container_unit_recovery_entry_complete, self(), @unit_name, make_ref()}
      )

      Process.sleep(50)
      assert :sys.get_state(pid).phase == :reconstructing
      assert FakeJournal.load_count() == journal_loads
      assert FakeReconciler.status_count() == status_loads
      assert Snapshot.load_count() == snap_loads

      # Authoritative absence + periodic reread reaches ready without the receipt.
      :ok = FakeJournal.set_entries([])
      await_ready(pid)
      assert :sys.get_state(pid).phase == :ready
    end

    test "lost receipt convergence: periodic reread alone reaches ready", %{holder: holder} do
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      Process.sleep(60)
      assert :sys.get_state(pid).phase == :reconstructing
      assert map_size(:sys.get_state(pid).pending_orphan_receipts) >= 1

      # Simulate lost recovery receipt: row disappears from journal without any
      # completion message. Snapshot reconcile must prune pending and open ready.
      :ok = FakeJournal.set_entries([])
      await_ready(pid)
      assert map_size(:sys.get_state(pid).pending_orphan_receipts) == 0
    end

    test "unmatched drain receipt and DOWN alone do not settle without reread", %{holder: holder} do
      worker = spawn_worker()
      :ok = FakeJournal.reset(entries: [])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: "exec-orphan-worker",
          journal_record: record(execution_id: "exec-orphan-worker")
        )

      pid = start_coord!(holder)
      Process.sleep(80)
      assert :sys.get_state(pid).phase == :reconstructing

      pending = FakeWorker.drain_pending()
      assert map_size(pending) >= 1
      [{^worker, {receipt_ref, _caller}}] = Map.to_list(pending)

      Process.exit(worker, :kill)
      Process.sleep(50)
      assert :sys.get_state(pid).phase == :reconstructing

      send(pid, {:apple_container_unit_drained, worker, "exec-orphan-worker", receipt_ref})
      Process.sleep(40)
      # Still reconstructing until snapshot proves worker absence.
      :ok = Snapshot.set({:ok, []})
      await_ready(pid)
    end

    test "forged messages do not increase journal/status/snapshot load counts", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      await_ready(pid)

      j0 = FakeJournal.load_count()
      s0 = FakeReconciler.status_count()
      sn0 = Snapshot.load_count()

      send(pid, {:apple_container_unit_recovery_entry_complete, self(), @unit_name, make_ref()})
      send(pid, {:apple_container_unit_drained, self(), @execution_id, make_ref()})
      send(pid, {:DOWN, make_ref(), :process, self(), :kill})
      send(pid, {:timeout, make_ref(), {:reconstruct, make_ref()}})
      send(pid, :reconstruct)

      Process.sleep(40)

      assert FakeJournal.load_count() == j0
      assert FakeReconciler.status_count() == s0
      assert Snapshot.load_count() == sn0
      assert :sys.get_state(pid).phase == :ready
    end
  end

  describe "exact timers" do
    test "stale reconstruct timer messages are ignored", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "unavailable")

      # Start closed with a slow retry so a timer is outstanding while we
      # inject a forged one.
      pid = start_coord!(holder, reconstruct_retry_ms: 500)
      Process.sleep(60)
      assert :sys.get_state(pid).phase == :reconstructing

      j0 = FakeJournal.load_count()
      send(pid, {:timeout, make_ref(), {:reconstruct, make_ref()}})
      Process.sleep(30)
      assert FakeJournal.load_count() == j0

      :ok = FakeReconciler.set_phase("ready")
      await_ready(pid)
    end
  end

  describe "durable start ordering and failure modes" do
    test "shared trace proves clock -> reserve -> worker-start and monitors before reply", %{
      holder: holder
    } do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")
      :ok = FakeWorker.reset(start_result: :spawn_worker)

      pid = start_coord!(holder)
      await_ready(pid)

      :ok = SharedTrace.reset()
      :ok = FakeClock.reset(5_000_000)
      start_ref = make_ref()
      spec = spec_fixture()

      assert {:ok, worker} =
               GenServer.call(
                 pid,
                 {:start_unit, spec, :executable, @execution_id, start_ref}
               )

      assert is_pid(worker)
      assert Process.alive?(worker)

      state = :sys.get_state(pid)
      assert Enum.any?(state.monitored, fn {_ref, meta} -> meta.worker_pid == worker end)

      trace = SharedTrace.events()

      assert trace == [
               :clock_monotonic,
               {:journal_reserve, @unit_name, @execution_id},
               {:worker_start, @execution_id, 5_000_000 + @timeout_ms}
             ]
    end

    test "definite start failure completes the exact row", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")
      :ok = FakeWorker.reset(start_result: {:error, :child_start_rejected})

      pid = start_coord!(holder)
      await_ready(pid)

      assert {:error, :child_start_rejected} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :executable, @execution_id, make_ref()}
               )

      events = FakeJournal.events()
      assert Enum.any?(events, &match?({:reserve_record, @unit_name, @execution_id}, &1))
      assert Enum.any?(events, &match?({:complete, @unit_name, @token}, &1))
      assert :sys.get_state(pid).phase == :ready
    end

    test "completion failure retains the row and re-enters reconstruction with recovery", %{
      holder: holder
    } do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [], complete_result: {:error, :journal_blocked})
      :ok = FakeReconciler.reset(phase: "ready")
      :ok = FakeWorker.reset(start_result: {:error, :child_start_rejected})

      pid = start_coord!(holder)
      await_ready(pid)

      assert {:error, :child_start_rejected} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :executable, @execution_id, make_ref()}
               )

      await_phase(pid, :reconstructing)

      assert Enum.any?(FakeJournal.events(), &match?({:complete, @unit_name, @token}, &1))

      assert Enum.any?(
               FakeReconciler.events(),
               &match?({:recover_entry, %{unit_name: @unit_name}, _, _}, &1)
             )

      assert {:ok, entries} = FakeJournal.recovery_entries()
      assert Enum.any?(entries, &(&1.unit_name == @unit_name and &1.token == @token))
    end

    test "security regression: ambiguous start exit retains row and does not complete", %{
      holder: holder
    } do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")

      # Starter admits a live worker process then exits — ambiguous because a
      # DynamicSupervisor child may already be live; must not Journal.complete.
      starter = fn _spec, _exec, _id, _ref, _ctrl, _record, _deadline ->
        _live = spawn(fn -> Process.sleep(:infinity) end)
        exit(:starter_crashed_after_admit)
      end

      pid = start_coord!(holder, worker_starter: starter)
      await_ready(pid)

      assert {:error, :unit_start_indeterminate} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :executable, @execution_id, make_ref()}
               )

      events = FakeJournal.events()
      assert Enum.any?(events, &match?({:reserve_record, @unit_name, @execution_id}, &1))
      refute Enum.any?(events, &match?({:complete, _, _}, &1))

      await_phase(pid, :reconstructing)
      assert {:ok, entries} = FakeJournal.recovery_entries()
      assert Enum.any?(entries, &(&1.unit_name == @unit_name and &1.token == @token))
    end

    test "ambiguous start reissues recovery after an initial rejection", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])

      :ok =
        FakeReconciler.reset(
          phase: "ready",
          recover_result: {:error, :recovery_temporarily_unavailable}
        )

      starter = fn _spec, _exec, _id, _ref, _ctrl, _record, _deadline ->
        exit(:starter_crashed_after_admit)
      end

      pid = start_coord!(holder, worker_starter: starter)
      await_ready(pid)

      assert {:error, :unit_start_indeterminate} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :executable, @execution_id, make_ref()}
               )

      eventually!(fn ->
        recoveries =
          Enum.count(FakeReconciler.events(), &match?({:recover_entry, _, _, _}, &1))

        recoveries >= 2
      end)

      assert :sys.get_state(pid).phase == :reconstructing
      assert map_size(:sys.get_state(pid).pending_orphan_receipts) == 0

      :ok = FakeJournal.set_entries([])
      await_ready(pid)
    end
  end

  describe "planned vs abnormal termination" do
    test "abnormal termination does not execute planned drain", %{holder: holder} do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      before = FakeWorker.events()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      after_events = FakeWorker.events()

      new_drains =
        after_events
        |> Enum.drop(length(before))
        |> Enum.filter(&match?({:request_drain, _, _, _}, &1))

      assert new_drains == []
    end

    test "planned GenServer.stop terminates promptly without barrier drain", %{holder: holder} do
      # terminate/2 no longer owns the planned barrier — crash/stop must stay
      # bounded so rest_for_one can restart earlier siblings.
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      before = length(FakeWorker.events())
      assert :ok = GenServer.stop(pid, :shutdown, 1_000)

      new_drains =
        FakeWorker.events()
        |> Enum.drop(before)
        |> Enum.filter(&match?({:request_drain, _, _, _}, &1))

      assert new_drains == []
    end
  end

  describe "durable prepare_durable_shutdown barrier" do
    test "drains live workers, recover_all, and empties durable state", %{holder: holder} do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      parent = self()

      barrier_task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      assert_receive {:barrier_started, _}, 1_000

      eventually!(fn ->
        Enum.any?(FakeWorker.events(), &match?({:request_drain, ^worker, _, _}, &1))
      end)

      # Nonblocking barrier: GenServer loop remains free for concurrent starts.
      assert {:error, :unit_start_unavailable} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :exec, "post-shutdown", make_ref()},
                 500
               )

      # :sys also works while barrier is in progress (not stuck in handle_call).
      assert :sys.get_state(pid).phase == :preparing_shutdown

      pending = FakeWorker.drain_pending()
      assert [{^worker, {receipt_ref, _caller}}] = Map.to_list(pending)
      :ok = Snapshot.set({:ok, []})
      assert :ok = FakeWorker.emit_drain(worker, @execution_id, receipt_ref)

      eventually!(fn ->
        Enum.any?(FakeReconciler.events(), &match?({:recover_all, _, _, _}, &1))
      end)

      [{all_ref, _caller}] = Map.to_list(FakeReconciler.recover_all_pending())
      :ok = FakeJournal.set_entries([])
      assert :ok = FakeReconciler.emit_recover_all(all_ref)

      assert :ok = Task.await(barrier_task, 5_000)
      assert :sys.get_state(pid).phase == :preparing_shutdown
      assert {:ok, []} = FakeJournal.recovery_entries()

      assert {:error, :unit_start_unavailable} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :exec, "still-closed", make_ref()}
               )
    end

    test "orphaned journal row is recovered during the full sweep", %{holder: holder} do
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :auto_complete)

      pid = start_coord!(holder)
      # May still be reconstructing (orphan recovery) or ready after loss.
      Process.sleep(80)

      assert :ok = Coordinator.prepare_durable_shutdown(pid)
      assert Enum.any?(FakeReconciler.events(), &match?({:recover_all, _, _, _}, &1))
      assert {:ok, []} = FakeJournal.recovery_entries()
      assert :sys.get_state(pid).phase == :preparing_shutdown
    end

    test "exact sender/ref matching ignores forged recovery completion", %{holder: holder} do
      :ok = FakeJournal.reset(entries: [record()])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      pid = start_coord!(holder)
      Process.sleep(60)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      assert_receive {:barrier_started, _}, 1_000

      eventually!(fn ->
        map_size(FakeReconciler.recover_all_pending()) >= 1
      end)

      [{all_ref, _caller}] = Map.to_list(FakeReconciler.recover_all_pending())

      # Forged completions must not settle the barrier.
      send(pid, {:apple_container_unit_recovery_all_complete, self(), all_ref})
      send(pid, {:apple_container_unit_recovery_all_complete, self(), make_ref()})

      send(
        pid,
        {:apple_container_unit_recovery_all_complete, FakeReconciler.ensure_started(), make_ref()}
      )

      Process.sleep(80)
      assert Process.alive?(task.pid)

      :ok = FakeJournal.set_entries([])
      assert :ok = FakeReconciler.emit_recover_all(all_ref)
      assert :ok = Task.await(task, 5_000)
    end

    test "reconciler PID turnover requires fresh ref and exact replacement receipt", %{
      holder: holder
    } do
      :ok = FakeJournal.reset(entries: [record()])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      pid = start_coord!(holder)
      Process.sleep(60)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      assert_receive {:barrier_started, _}, 1_000

      eventually!(fn ->
        map_size(FakeReconciler.recover_all_pending()) >= 1
      end)

      old_reconciler = Process.whereis(FakeReconciler)
      assert is_pid(old_reconciler)
      [{old_ref, _caller}] = Map.to_list(FakeReconciler.recover_all_pending())

      # Kill the exact accepted reconciler PID; replacement must be re-resolved.
      # Keep the coordinator from observing the replacement between its default
      # init and the test's hold-mode reset.
      :ok = :sys.suspend(pid)
      ref = Process.monitor(old_reconciler)
      Process.exit(old_reconciler, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_reconciler, _}, 1_000

      # Restart fake reconciler under same name with hold mode so we can prove
      # a fresh receipt_ref is issued against the new PID.
      FakeReconciler.ensure_started()
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)
      :ok = FakeJournal.set_entries([])
      :ok = :sys.resume(pid)

      eventually!(fn ->
        pending = FakeReconciler.recover_all_pending()
        map_size(pending) >= 1 and not Map.has_key?(pending, old_ref)
      end)

      new_reconciler = Process.whereis(FakeReconciler)
      assert is_pid(new_reconciler)
      assert new_reconciler != old_reconciler

      [{new_ref, _}] = Map.to_list(FakeReconciler.recover_all_pending())
      assert new_ref != old_ref

      # Stale completion from old PID/ref must not settle.
      send(pid, {:apple_container_unit_recovery_all_complete, old_reconciler, old_ref})
      send(pid, {:apple_container_unit_recovery_all_complete, new_reconciler, old_ref})
      Process.sleep(40)
      assert Process.alive?(task.pid)

      assert :ok = FakeReconciler.emit_recover_all(new_ref)
      assert :ok = Task.await(task, 5_000)

      # Replacement process issued recover_all (events reset with the new PID).
      assert Enum.any?(FakeReconciler.events(), &match?({:recover_all, ^new_ref, _, _}, &1))
    end

    test "disabled journal succeeds only with a positive empty UnitSupervisor snapshot", %{
      holder: holder
    } do
      :ok = Snapshot.set({:error, :unit_supervisor_unavailable})
      :ok = FakeJournal.reset(recovery_result: {:error, :apple_container_unit_journal_disabled})
      :ok = FakeReconciler.reset(phase: "unavailable")

      pid = start_coord!(holder)
      Process.sleep(40)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      assert_receive {:barrier_started, _}, 1_000
      Process.sleep(100)
      # Missing supervisor is UNKNOWN — barrier must not succeed yet.
      assert Process.alive?(task.pid)

      :ok = Snapshot.set({:ok, []})
      assert :ok = Task.await(task, 5_000)
      # Disabled path must not invoke recover_all (no durable rows possible).
      refute Enum.any?(FakeReconciler.events(), &match?({:recover_all, _, _, _}, &1))
    end

    test "unavailable journal is never treated as empty even with empty snapshot", %{
      holder: holder
    } do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(recovery_result: {:error, :journal_poisoned})
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :auto_complete)

      pid = start_coord!(holder)
      Process.sleep(40)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      assert_receive {:barrier_started, _}, 1_000
      Process.sleep(120)
      assert Process.alive?(task.pid)

      # Heal journal to empty — barrier can complete via recover_all.
      :ok = FakeJournal.reset(entries: [])
      assert :ok = Task.await(task, 5_000)
    end

    test "start requests are rejected immediately once shutdown preparation starts", %{
      holder: holder
    } do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      pid = start_coord!(holder)
      await_ready(pid)

      parent = self()

      barrier_task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      assert_receive {:barrier_started, _}, 1_000

      eventually!(fn ->
        Enum.any?(FakeReconciler.events(), &match?({:recover_all, _, _, _}, &1))
      end)

      # Immediate rejection while barrier is still waiting (nonblocking loop).
      assert {:error, :unit_start_unavailable} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :executable, @execution_id, make_ref()},
                 200
               )

      [{all_ref, _}] = Map.to_list(FakeReconciler.recover_all_pending())
      assert :ok = FakeReconciler.emit_recover_all(all_ref)
      assert :ok = Task.await(barrier_task, 5_000)
      assert :sys.get_state(pid).phase == :preparing_shutdown
    end

    test "active barrier does not block rest_for_one when earlier sibling crashes", %{
      holder: holder
    } do
      # Deterministic parent-shutdown race: hold barrier mid-recover_all, then
      # crash an earlier rest_for_one sibling. Coordinator must exit promptly so
      # the dependency can restart (blocking handle_call receive would deadlock).
      :ok = Snapshot.set({:ok, []})
      # Start ready, then inject an orphan row so barrier holds on recover_all.
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      parent = self()

      children = [
        %{
          id: :earlier_sibling,
          start: {Agent, :start_link, [fn -> :ok end]},
          restart: :permanent,
          shutdown: 500,
          type: :worker
        },
        %{
          id: :drain_coord,
          start: {__MODULE__, :start_coord_for_race, [holder, parent]},
          restart: :permanent,
          shutdown: 1_000,
          type: :worker
        }
      ]

      {:ok, sup} =
        Supervisor.start_link(children,
          strategy: :rest_for_one,
          max_restarts: 20,
          max_seconds: 5
        )

      on_exit(fn ->
        if Process.alive?(sup), do: Process.exit(sup, :kill)
      end)

      assert_receive {:race_coord_started, coord_pid}, 2_000
      await_ready(coord_pid)

      :ok = FakeJournal.set_entries([record()])
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      barrier_task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(coord_pid)
        end)

      assert_receive {:barrier_started, _}, 1_000

      eventually!(fn ->
        map_size(FakeReconciler.recover_all_pending()) >= 1
      end)

      # Prove loop is free mid-barrier.
      assert :sys.get_state(coord_pid).phase == :preparing_shutdown

      earlier =
        Enum.find_value(Supervisor.which_children(sup), fn
          {:earlier_sibling, pid, _, _} when is_pid(pid) -> pid
          _ -> nil
        end)

      assert is_pid(earlier)
      started = System.monotonic_time(:millisecond)
      mon = Process.monitor(earlier)
      Process.exit(earlier, :kill)
      assert_receive {:DOWN, ^mon, :process, ^earlier, _}, 2_000

      # Coordinator must be replaced promptly (not stuck in barrier receive).
      eventually!(fn ->
        children_now = Supervisor.which_children(sup)

        Enum.any?(children_now, fn
          {:drain_coord, p, _, _} when is_pid(p) and p != coord_pid -> true
          _ -> false
        end)
      end)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_000

      # Original barrier caller observes coordinator death (prep_stop retries).
      result = Task.await(barrier_task, 2_000)
      assert match?({:error, {:coordinator_unavailable, _}}, result)
    end
  end

  # Helper for rest_for_one race child start (must be public MFA).
  def start_coord_for_race(holder, parent) do
    opts = [
      journal: FakeJournal,
      journal_server: FakeJournal,
      reconciler: FakeReconciler,
      reconciler_server: FakeReconciler,
      unit_supervisor: :unused_supervisor,
      worker_module: FakeWorker,
      clock: FakeClock,
      snapshot_workers: &Snapshot.snapshot/0,
      reconstruct_retry_ms: 30,
      ownership_call_timeout_ms: 1_000,
      drain_handshake_timeout_ms: 1_000
    ]

    case Coordinator.start_for_test(opts) do
      {:ok, pid} = ok ->
        if Process.alive?(holder), do: Agent.update(holder, fn _ -> pid end)
        send(parent, {:race_coord_started, pid})
        ok

      other ->
        other
    end
  end

  describe "await_execution_settled" do
    test "absent execution forces a fresh authoritative reread before :ok", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      await_ready(pid)

      j0 = FakeJournal.load_count()
      s0 = FakeReconciler.status_count()
      sn0 = Snapshot.load_count()

      assert :ok = Coordinator.await_execution_settled("exec-never-existed", pid)

      assert FakeJournal.load_count() > j0
      assert FakeReconciler.status_count() > s0
      assert Snapshot.load_count() > sn0
      assert :sys.get_state(pid).phase == :ready
      assert map_size(:sys.get_state(pid).execution_waiters) == 0
    end

    test "retained ambiguous-start row holds the waiter until recovery and fresh reread", %{
      holder: holder
    } do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")

      starter = fn _spec, _exec, _id, _ref, _ctrl, _record, _deadline ->
        exit(:starter_crashed_after_admit)
      end

      pid = start_coord!(holder, worker_starter: starter)
      await_ready(pid)

      assert {:error, :unit_start_indeterminate} =
               GenServer.call(
                 pid,
                 {:start_unit, spec_fixture(), :executable, @execution_id, make_ref()}
               )

      await_phase(pid, :reconstructing)
      assert {:ok, entries} = FakeJournal.recovery_entries()
      assert Enum.any?(entries, &(&1.execution_id == @execution_id))

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:settlement_started, self()})
          Coordinator.await_execution_settled(@execution_id, pid)
        end)

      assert_receive {:settlement_started, _}, 1_000
      Process.sleep(80)
      assert Process.alive?(task.pid)
      assert map_size(:sys.get_state(pid).execution_waiters) == 1

      # Forged recovery / drain / DOWN cannot settle the waiter.
      send(
        pid,
        {:apple_container_unit_recovery_entry_complete, self(), @unit_name, make_ref()}
      )

      send(pid, {:apple_container_unit_drained, self(), @execution_id, make_ref()})
      send(pid, {:DOWN, make_ref(), :process, self(), :kill})
      Process.sleep(40)
      assert Process.alive?(task.pid)

      :ok = FakeJournal.set_entries([])
      assert :ok = Task.await(task, 5_000)
      assert :sys.get_state(pid).phase == :ready
      assert map_size(:sys.get_state(pid).execution_waiters) == 0
    end

    test "row absent but unresolved live worker cannot settle", %{holder: holder} do
      worker = spawn_worker()
      :ok = FakeJournal.reset(entries: [])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: record()
        )

      pid = start_coord!(holder)
      Process.sleep(80)
      assert :sys.get_state(pid).phase == :reconstructing

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:settlement_started, self()})
          Coordinator.await_execution_settled(@execution_id, pid)
        end)

      assert_receive {:settlement_started, _}, 1_000
      Process.sleep(80)
      assert Process.alive?(task.pid)

      pending = FakeWorker.drain_pending()
      assert map_size(pending) >= 1
      [{^worker, {receipt_ref, _caller}}] = Map.to_list(pending)

      # Receipt alone is insufficient without an empty live snapshot.
      assert :ok = FakeWorker.emit_drain(worker, @execution_id, receipt_ref)
      Process.sleep(40)
      assert Process.alive?(task.pid)

      :ok = Snapshot.set({:ok, []})
      assert :ok = Task.await(task, 5_000)
      assert :sys.get_state(pid).phase == :ready
    end

    test "journal reconciler or supervisor unavailability cannot settle", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      await_ready(pid)

      :ok = FakeJournal.reset(recovery_result: {:error, :journal_poisoned})
      :ok = FakeReconciler.set_phase("unavailable")
      :ok = Snapshot.set({:error, :unit_supervisor_unavailable})

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:settlement_started, self()})
          Coordinator.await_execution_settled("exec-unknown-deps", pid)
        end)

      assert_receive {:settlement_started, _}, 1_000
      Process.sleep(120)
      assert Process.alive?(task.pid)
      assert map_size(:sys.get_state(pid).execution_waiters) == 1

      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.set_phase("ready")
      :ok = Snapshot.set({:ok, []})
      assert :ok = Task.await(task, 5_000)
    end

    test "caller death removes only its waiter; other waiters remain", %{holder: holder} do
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      Process.sleep(60)
      assert :sys.get_state(pid).phase == :reconstructing

      parent = self()

      # Unlinked so killing the waiter cannot take down the ExUnit process.
      dying_pid =
        spawn(fn ->
          send(parent, {:dying_started, self()})
          _ = Coordinator.await_execution_settled(@execution_id, pid)
        end)

      survivor =
        Task.async(fn ->
          send(parent, {:survivor_started, self()})
          Coordinator.await_execution_settled(@execution_id, pid)
        end)

      assert_receive {:dying_started, ^dying_pid}, 1_000
      assert_receive {:survivor_started, _}, 1_000

      eventually!(fn -> map_size(:sys.get_state(pid).execution_waiters) == 2 end)

      mon = Process.monitor(dying_pid)
      Process.exit(dying_pid, :kill)
      assert_receive {:DOWN, ^mon, :process, ^dying_pid, :killed}, 1_000

      eventually!(fn -> map_size(:sys.get_state(pid).execution_waiters) == 1 end)
      assert Process.alive?(survivor.pid)

      # Forged DOWN must not remove the remaining waiter.
      send(pid, {:DOWN, make_ref(), :process, survivor.pid, :kill})
      Process.sleep(30)
      assert map_size(:sys.get_state(pid).execution_waiters) == 1
      assert Process.alive?(survivor.pid)

      :ok = FakeJournal.set_entries([])
      assert :ok = Task.await(survivor, 5_000)
      assert map_size(:sys.get_state(pid).execution_waiters) == 0
    end

    test "active shutdown barrier convergence settles execution waiters", %{holder: holder} do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready", recover_all_mode: :hold)

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      parent = self()

      barrier_task =
        Task.async(fn ->
          send(parent, {:barrier_started, self()})
          Coordinator.prepare_durable_shutdown(pid)
        end)

      settle_task =
        Task.async(fn ->
          send(parent, {:settlement_started, self()})
          Coordinator.await_execution_settled(@execution_id, pid)
        end)

      assert_receive {:barrier_started, _}, 1_000
      assert_receive {:settlement_started, _}, 1_000

      eventually!(fn ->
        Enum.any?(FakeWorker.events(), &match?({:request_drain, ^worker, _, _}, &1))
      end)

      assert :sys.get_state(pid).phase == :preparing_shutdown
      assert map_size(:sys.get_state(pid).execution_waiters) >= 1

      pending = FakeWorker.drain_pending()
      [{^worker, {receipt_ref, _caller}}] = Map.to_list(pending)
      :ok = Snapshot.set({:ok, []})
      assert :ok = FakeWorker.emit_drain(worker, @execution_id, receipt_ref)

      eventually!(fn ->
        map_size(FakeReconciler.recover_all_pending()) >= 1
      end)

      [{all_ref, _}] = Map.to_list(FakeReconciler.recover_all_pending())
      :ok = FakeJournal.set_entries([])
      assert :ok = FakeReconciler.emit_recover_all(all_ref)

      assert :ok = Task.await(barrier_task, 5_000)
      assert :ok = Task.await(settle_task, 5_000)
      assert map_size(:sys.get_state(pid).execution_waiters) == 0
    end

    test "invalid execution id is rejected without registering a waiter", %{holder: holder} do
      :ok = Snapshot.set({:ok, []})
      :ok = FakeJournal.reset(entries: [])
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      await_ready(pid)

      assert {:error, :invalid_execution_id} =
               Coordinator.await_execution_settled("", pid)

      assert {:error, :invalid_execution_id} =
               Coordinator.await_execution_settled(:not_a_binary, pid)

      assert map_size(:sys.get_state(pid).execution_waiters) == 0
    end

    test "coordinator turnover returns bounded coordinator_unavailable", %{holder: holder} do
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      Process.sleep(60)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:settlement_started, self()})
          Coordinator.await_execution_settled(@execution_id, pid)
        end)

      assert_receive {:settlement_started, _}, 1_000
      eventually!(fn -> map_size(:sys.get_state(pid).execution_waiters) == 1 end)

      Process.exit(pid, :kill)
      result = Task.await(task, 2_000)
      assert match?({:error, {:coordinator_unavailable, _}}, result)
    end

    test "format_status does not expose execution waiter from/PID/ref authority", %{
      holder: holder
    } do
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, []})
      :ok = FakeReconciler.reset(phase: "ready")

      pid = start_coord!(holder)
      Process.sleep(60)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:settlement_started, self()})
          Coordinator.await_execution_settled(@execution_id, pid)
        end)

      assert_receive {:settlement_started, waiter_pid}, 1_000
      eventually!(fn -> map_size(:sys.get_state(pid).execution_waiters) == 1 end)

      state = :sys.get_state(pid)
      redacted = Coordinator.format_status(%{state: state, message: {:await, @execution_id}})

      assert redacted.state.execution_waiters == :redacted
      assert is_integer(redacted.state.execution_waiter_count)
      assert redacted.state.execution_waiter_count >= 1
      assert redacted.message == :redacted

      rendered = inspect(redacted)
      refute rendered =~ @execution_id
      refute rendered =~ inspect(waiter_pid)
      refute rendered =~ "#Reference"

      {:status, ^pid, {:module, _mod}, status_body} = :sys.get_status(pid)
      status_text = inspect(status_body)
      refute status_text =~ @execution_id
      refute status_text =~ inspect(waiter_pid)
      assert status_text =~ "redacted"

      :ok = FakeJournal.set_entries([])
      assert :ok = Task.await(task, 5_000)
    end
  end

  describe "status redaction" do
    test "format_status redacts durable and test authority", %{holder: holder} do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      redacted =
        Coordinator.format_status(%{
          state: :sys.get_state(pid),
          message: {:start_unit, rec},
          reason: {@token, @execution_id},
          log: [rec]
        })

      assert redacted.state.monitored == :redacted
      assert redacted.state.pending_orphan_receipts == :redacted
      assert redacted.state.pending_drain == :redacted
      assert redacted.state.execution_waiters == :redacted
      assert redacted.state.journal == :redacted
      assert redacted.state.worker_module == :redacted
      assert redacted.state.clock == :redacted
      assert redacted.state.worker_starter == :redacted
      assert redacted.state.snapshot_workers == :redacted
      assert redacted.message == :redacted
      assert redacted.reason == :redacted
      assert redacted.log == :redacted

      rendered = inspect(redacted)
      refute rendered =~ @token
      refute rendered =~ @execution_id
      refute rendered =~ "FakeJournal"

      {:status, ^pid, {:module, _mod}, status_body} = :sys.get_status(pid)
      status_text = inspect(status_body)
      refute status_text =~ @token
      refute status_text =~ @execution_id
      assert status_text =~ "redacted"
    end
  end

  describe "ready-state worker DOWN reopens reconstruction" do
    test "monitored worker DOWN re-enters closed reconstruction when row remains", %{
      holder: holder
    } do
      worker = spawn_worker()
      rec = record()
      :ok = FakeJournal.reset(entries: [rec])
      :ok = Snapshot.set({:ok, [worker]})
      :ok = FakeReconciler.reset(phase: "ready")

      :ok =
        FakeWorker.register_worker(worker,
          execution_id: @execution_id,
          journal_record: rec
        )

      pid = start_coord!(holder)
      await_ready(pid)

      :ok = Snapshot.set({:ok, []})
      Process.exit(worker, :kill)
      await_phase(pid, :reconstructing)

      assert {:error, :unit_start_unavailable} =
               GenServer.call(pid, {:start_unit, spec_fixture(), :exec, "x", make_ref()})

      eventually!(fn ->
        Enum.any?(
          FakeReconciler.events(),
          &match?({:recover_entry, %{unit_name: @unit_name}, _, _}, &1)
        )
      end)
    end
  end
end
