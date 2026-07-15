defmodule Arbor.Shell.AppleContainerUnitRecoveryReconcilerTest do
  @moduledoc """
  Independent Apple Container recovery reconciler/supervisor tests.

  Uses deterministic same-library fakes only — never real `container` commands.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.AppleContainerUnitRecoveryReconciler, as: Reconciler
  alias Arbor.Shell.AppleContainerUnitRecoverySupervisor
  alias Arbor.Shell.ExecutablePolicy.Executable

  @moduletag :fast

  @runtime_path "/usr/local/bin/container"
  @hex32 String.duplicate("a", 32)
  @unit_name "arbor-v1-#{@hex32}"
  @token String.duplicate("b", 64)
  @execution_id "exec-rec-1"
  @reserved_at_ms 1_700_000_000_000

  @hex32_b String.duplicate("c", 32)
  @unit_name_b "arbor-v1-#{@hex32_b}"
  @token_b String.duplicate("d", 64)

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  defmodule FakeJournal do
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

    def set_entries(entries) when is_list(entries) do
      ensure_started()
      GenServer.call(__MODULE__, {:set_entries, entries})
    end

    def remove_exact(unit_name, token) do
      ensure_started()
      GenServer.call(__MODULE__, {:remove_exact, unit_name, token})
    end

    def replace_entry(unit_name, new_entry) when is_map(new_entry) do
      ensure_started()
      GenServer.call(__MODULE__, {:replace_entry, unit_name, new_entry})
    end

    def recovery_entries(server \\ __MODULE__) do
      GenServer.call(server, :recovery_entries)
    end

    def load_count do
      ensure_started()
      GenServer.call(__MODULE__, :load_count)
    end

    @impl true
    def init(_) do
      {:ok, %{entries: [], results: :entries, load_count: 0, fail_times: 0}}
    end

    @impl true
    def handle_call({:reset, opts}, _from, _state) do
      {:reply, :ok,
       %{
         entries: Keyword.get(opts, :entries, []),
         results: Keyword.get(opts, :results, :entries),
         load_count: 0,
         fail_times: Keyword.get(opts, :fail_times, 0),
         fail_reason: Keyword.get(opts, :fail_reason, :apple_container_unit_journal_disabled)
       }}
    end

    def handle_call({:set_entries, entries}, _from, state) do
      {:reply, :ok, %{state | entries: entries, results: :entries}}
    end

    def handle_call({:remove_exact, unit_name, token}, _from, state) do
      entries =
        Enum.reject(state.entries, fn e ->
          name = e["unit_name"] || e[:unit_name]
          tok = e["token"] || e[:token]
          name == unit_name and tok == token
        end)

      {:reply, :ok, %{state | entries: entries}}
    end

    def handle_call({:replace_entry, unit_name, new_entry}, _from, state) do
      entries =
        state.entries
        |> Enum.reject(fn e ->
          name = e["unit_name"] || e[:unit_name]
          name == unit_name
        end)
        |> Kernel.++([new_entry])

      {:reply, :ok, %{state | entries: entries}}
    end

    def handle_call(:load_count, _from, state) do
      {:reply, state.load_count, state}
    end

    def handle_call(:recovery_entries, _from, state) do
      state = %{state | load_count: state.load_count + 1}

      cond do
        state.fail_times > 0 ->
          {:reply, {:error, state.fail_reason}, %{state | fail_times: state.fail_times - 1}}

        state.results == :entries ->
          {:reply, {:ok, state.entries}, state}

        is_list(state.results) ->
          case state.results do
            [result | rest] ->
              {:reply, result, %{state | results: rest}}

            [] ->
              {:reply, {:ok, state.entries}, state}
          end

        true ->
          {:reply, {:error, :journal_unavailable}, state}
      end
    end
  end

  defmodule FakeCoordinator do
    @moduledoc false
    use GenServer

    def start_link(name) do
      GenServer.start_link(__MODULE__, %{caller: nil}, name: name)
    end

    def set_caller(name, pid) do
      GenServer.call(name, {:set_caller, pid})
    end

    def recover_entry(reconciler, name, record, receipt_ref) do
      GenServer.call(name, {:recover_entry, reconciler, record, receipt_ref})
    end

    def recover_all(reconciler, name, receipt_ref) do
      GenServer.call(name, {:recover_all, reconciler, receipt_ref})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:set_caller, pid}, _from, state) do
      {:reply, :ok, %{state | caller: pid}}
    end

    def handle_call({:recover_entry, reconciler, record, receipt_ref}, _from, state) do
      reply = Reconciler.recover_entry(record, receipt_ref, reconciler)
      {:reply, reply, state}
    end

    def handle_call({:recover_all, reconciler, receipt_ref}, _from, state) do
      reply = Reconciler.recover_all(receipt_ref, reconciler)
      {:reply, reply, state}
    end

    @impl true
    def handle_info(msg, %{caller: caller} = state) when is_pid(caller) do
      send(caller, msg)
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  defmodule WorkerScript do
    @moduledoc false
    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(script) when is_list(script) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, script})
    end

    def next_action do
      ensure_started()
      GenServer.call(__MODULE__, :next)
    end

    def starts do
      ensure_started()
      GenServer.call(__MODULE__, :starts)
    end

    def register_pid(pid) when is_pid(pid) do
      ensure_started()
      GenServer.call(__MODULE__, {:register_pid, pid})
    end

    def worker_pids do
      ensure_started()
      GenServer.call(__MODULE__, :worker_pids)
    end

    @impl true
    def init(_) do
      {:ok, %{script: [], starts: [], pids: []}}
    end

    @impl true
    def handle_call({:reset, script}, _from, _state) do
      {:reply, :ok, %{script: script, starts: [], pids: []}}
    end

    def handle_call(:starts, _from, state) do
      {:reply, Enum.reverse(state.starts), state}
    end

    def handle_call({:register_pid, pid}, _from, state) do
      {:reply, :ok, %{state | pids: state.pids ++ [pid]}}
    end

    def handle_call(:worker_pids, _from, state) do
      {:reply, state.pids, state}
    end

    def handle_call(:next, _from, state) do
      case state.script do
        [action | rest] ->
          {:reply, action, %{state | script: rest, starts: [action | state.starts]}}

        [] ->
          {:reply, :complete_and_remove, %{state | starts: [:complete_and_remove | state.starts]}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    Process.flag(:trap_exit, true)
    FakeJournal.ensure_started()
    WorkerScript.ensure_started()
    :ok = FakeJournal.reset()
    :ok = WorkerScript.reset([])

    coordinator_name = :"test_recovery_coord_#{System.unique_integer([:positive])}"
    reconciler_name = :"test_recovery_reconciler_#{System.unique_integer([:positive])}"
    worker_sup_name = :"test_recovery_worker_sup_#{System.unique_integer([:positive])}"

    {:ok, _coord} = FakeCoordinator.start_link(coordinator_name)
    :ok = FakeCoordinator.set_caller(coordinator_name, self())

    {:ok, worker_sup} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: worker_sup_name)

    executable = %Executable{
      name: "container",
      path: @runtime_path,
      device: 1,
      inode: 1,
      size: 1,
      mtime: 1,
      ctime: 1,
      mode: 0o755,
      sha256: String.duplicate("c", 64)
    }

    entry = %{
      "unit_name" => @unit_name,
      "execution_id" => @execution_id,
      "token" => @token,
      "reserved_at_ms" => @reserved_at_ms
    }

    launcher = fn entry, owner, receipt_ref, _sup ->
      action = WorkerScript.next_action()
      unit_name = entry["unit_name"]
      token = entry["token"]

      pid =
        spawn(fn ->
          case action do
            :complete_and_remove ->
              :ok = FakeJournal.remove_exact(unit_name, token)
              send(owner, {:apple_container_unit_recovered, self(), unit_name, receipt_ref})

            :complete_without_remove ->
              send(owner, {:apple_container_unit_recovered, self(), unit_name, receipt_ref})

            :crash_before_receipt ->
              exit(:kill)

            :crash_after_remove ->
              :ok = FakeJournal.remove_exact(unit_name, token)
              exit(:kill)

            :hang ->
              Process.sleep(60_000)

            {:delay_complete, ms} ->
              Process.sleep(ms)
              :ok = FakeJournal.remove_exact(unit_name, token)
              send(owner, {:apple_container_unit_recovered, self(), unit_name, receipt_ref})
          end
        end)

      :ok = WorkerScript.register_pid(pid)
      {:ok, pid}
    end

    start_reconciler = fn opts ->
      base = [
        name: reconciler_name,
        journal: FakeJournal,
        journal_server: FakeJournal,
        worker_supervisor: worker_sup_name,
        worker_launcher: launcher,
        executable: executable,
        coordinator_module: coordinator_name
      ]

      Reconciler.start_for_test(Keyword.merge(base, opts))
    end

    on_exit(fn ->
      for name <- [reconciler_name, worker_sup_name, coordinator_name] do
        case Process.whereis(name) do
          pid when is_pid(pid) -> Process.exit(pid, :kill)
          _missing -> :ok
        end
      end
    end)

    {:ok,
     coordinator_name: coordinator_name,
     reconciler_name: reconciler_name,
     worker_sup: worker_sup,
     worker_sup_name: worker_sup_name,
     executable: executable,
     entry: entry,
     start_reconciler: start_reconciler}
  end

  defp await_ready(server, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      status = Reconciler.status(server)
      phase = status["phase"]

      if phase in ["ready", "recovering"] and status["awaiting_journal"] != true do
        if phase == "ready" or status["worker_count"] == 0 do
          :ready
        else
          :wait
        end
      else
        :wait
      end
    end)
    |> Enum.reduce_while(nil, fn
      :ready, _ ->
        {:halt, :ok}

      :wait, _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("reconciler not ready: #{inspect(Reconciler.status(server))}")
        else
          Process.sleep(10)
          {:cont, nil}
        end
    end)
  end

  defp await_phase(server, phase, timeout \\ 2_000) when is_binary(phase) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> Reconciler.status(server)["phase"] end)
    |> Enum.reduce_while(nil, fn
      ^phase, _ ->
        {:halt, :ok}

      _other, _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("expected phase #{phase}, got #{inspect(Reconciler.status(server))}")
        else
          Process.sleep(10)
          {:cont, nil}
        end
    end)
  end

  # ---------------------------------------------------------------------------
  # Startup barrier
  # ---------------------------------------------------------------------------

  describe "empty startup barrier" do
    test "becomes ready when journal is empty", %{start_reconciler: start} do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)
      status = Reconciler.status(pid)
      assert status["phase"] == "ready"
      assert status["worker_count"] == 0
    end
  end

  describe "nonempty startup cleanup" do
    test "starts workers and reaches ready after cleanup", %{
      start_reconciler: start,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [entry])
      :ok = WorkerScript.reset([:complete_and_remove])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      assert FakeJournal.recovery_entries() == {:ok, []}
      assert length(WorkerScript.starts()) >= 1
      assert Reconciler.status(pid)["phase"] == "ready"
    end
  end

  describe "journal unavailable retry" do
    test "retries without becoming ready on empty assumption", %{start_reconciler: start} do
      :ok =
        FakeJournal.reset(
          fail_times: 2,
          fail_reason: :apple_container_unit_journal_disabled,
          entries: []
        )

      assert {:ok, pid} = start.([])

      # Still closed while failing.
      Process.sleep(30)
      status = Reconciler.status(pid)
      assert status["phase"] in ["closed", "startup"]
      refute status["phase"] == "ready"

      await_ready(pid)
      assert Reconciler.status(pid)["phase"] == "ready"
      assert FakeJournal.load_count() >= 3
    end
  end

  # ---------------------------------------------------------------------------
  # Coordinator APIs
  # ---------------------------------------------------------------------------

  describe "authorized recover_entry" do
    test "accepts and completes for exact journal record", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:complete_and_remove])
      receipt_ref = make_ref()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     2_000

      # Never leak token/execution_id in completion message.
      refute_received {:apple_container_unit_recovery_entry_complete, _, _, _, _}
    end
  end

  describe "authorized recover_all" do
    test "sweeps full journal and completes once empty", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      entry_b = %{
        "unit_name" => @unit_name_b,
        "execution_id" => "exec-rec-2",
        "token" => @token_b,
        "reserved_at_ms" => @reserved_at_ms
      }

      :ok = FakeJournal.set_entries([entry, entry_b])
      :ok = WorkerScript.reset([:complete_and_remove, :complete_and_remove])
      receipt_ref = make_ref()

      assert :ok = FakeCoordinator.recover_all(pid, coord, receipt_ref)

      assert_receive {:apple_container_unit_recovery_all_complete, ^pid, ^receipt_ref}, 2_000
      assert FakeJournal.recovery_entries() == {:ok, []}
    end
  end

  describe "unauthorized caller rejection" do
    test "rejects non-coordinator caller", %{start_reconciler: start, entry: entry} do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])

      assert {:error, :unauthorized_recovery_caller} =
               Reconciler.recover_entry(entry, make_ref(), pid)

      assert {:error, :unauthorized_recovery_caller} =
               Reconciler.recover_all(make_ref(), pid)
    end

    test "rejects before ready", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok =
        FakeJournal.reset(
          fail_times: 50,
          fail_reason: :apple_container_unit_journal_disabled,
          entries: []
        )

      assert {:ok, pid} = start.([])

      assert {:error, :reconciler_not_ready} =
               FakeCoordinator.recover_entry(pid, coord, entry, make_ref())
    end
  end

  describe "dedupe" do
    test "second exact recover_entry does not double-start", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:hang])
      ref1 = make_ref()
      ref2 = make_ref()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, ref1)
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, ref2)

      Process.sleep(50)
      starts = WorkerScript.starts()
      assert length(starts) == 1
    end
  end

  describe "identity mismatch" do
    test "rejects when journal unit identity differs", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      wrong = %{entry | "token" => String.duplicate("e", 64)}
      :ok = FakeJournal.set_entries([entry])

      assert {:error, :identity_mismatch} =
               FakeCoordinator.recover_entry(pid, coord, wrong, make_ref())
    end
  end

  # ---------------------------------------------------------------------------
  # Worker lifecycle
  # ---------------------------------------------------------------------------

  describe "worker crash before journal completion" do
    test "restarts with backoff while entry remains", %{
      start_reconciler: start,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [entry])
      :ok = WorkerScript.reset([:crash_before_receipt, :complete_and_remove])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      assert length(WorkerScript.starts()) >= 2
      assert FakeJournal.recovery_entries() == {:ok, []}
    end
  end

  describe "worker crash after journal completion" do
    test "settles when journal entry already removed", %{
      start_reconciler: start,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [entry])
      :ok = WorkerScript.reset([:crash_after_remove])
      assert {:ok, pid} = start.([])
      await_ready(pid)
      assert FakeJournal.recovery_entries() == {:ok, []}
    end
  end

  describe "stale and forged receipts" do
    test "forged receipts never complete requests", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:hang])
      receipt_ref = make_ref()
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      # Forged recovery receipt with wrong ref.
      send(pid, {:apple_container_unit_recovered, self(), @unit_name, make_ref()})
      refute_receive {:apple_container_unit_recovery_entry_complete, _, _, _}, 150

      # Still recovering.
      assert Reconciler.status(pid)["phase"] == "recovering"
    end
  end

  describe "no autonomous sweep after ready" do
    test "new journal rows are not started without coordinator request", %{
      start_reconciler: start,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      loads_before = FakeJournal.load_count()
      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:complete_and_remove])

      Process.sleep(200)
      assert WorkerScript.starts() == []
      assert FakeJournal.load_count() == loads_before
      assert Reconciler.status(pid)["phase"] == "ready"
      assert FakeJournal.recovery_entries() == {:ok, [entry]}
    end
  end

  describe "journal unavailable after receipt retains request" do
    test "does not notify from receipt alone", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])

      # Worker removes entry and sends receipt; subsequent verifies fail then succeed.
      :ok = WorkerScript.reset([:complete_and_remove])

      # After worker completes, inject temporary journal failures on subsequent loads.
      # First recover_entry verify-contains uses success; later verify may fail.
      receipt_ref = make_ref()

      # Use scripted results: contain check, then fail, then empty success.
      # recover_entry does its own recovery_entries for contain check.
      # contain check + immediate receipt/DOWN verifies + delayed retries.
      :ok =
        FakeJournal.reset(
          entries: [entry],
          results: [
            {:ok, [entry]},
            {:error, :journal_unavailable},
            {:error, :journal_unavailable},
            {:error, :journal_unavailable},
            {:error, :journal_unavailable},
            {:error, :journal_unavailable},
            {:ok, []}
          ]
        )

      :ok = WorkerScript.reset([:complete_and_remove])

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      # Must not complete from the receipt alone while journal errors remain.
      refute_receive {:apple_container_unit_recovery_entry_complete, _, _, _}, 120

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     3_000
    end
  end

  describe "retry without tight loop" do
    test "journal failure uses exponential delay floor", %{start_reconciler: start} do
      :ok =
        FakeJournal.reset(
          fail_times: 3,
          fail_reason: :apple_container_unit_journal_disabled,
          entries: []
        )

      t0 = System.monotonic_time(:millisecond)
      assert {:ok, pid} = start.([])
      await_ready(pid)
      elapsed = System.monotonic_time(:millisecond) - t0

      # 50 + 100 + 200 = 350ms minimum for three failures before empty success.
      assert elapsed >= 300
      assert Reconciler.status(pid)["phase"] == "ready"
    end
  end

  describe "redaction" do
    test "status and format_status omit secrets", %{
      start_reconciler: start,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [entry])
      :ok = WorkerScript.reset([:hang])
      assert {:ok, pid} = start.([])
      await_phase(pid, "startup")

      status = Reconciler.status(pid)
      encoded = inspect(status)
      refute encoded =~ @token
      refute encoded =~ @execution_id
      assert Map.has_key?(status, "phase")
      assert Map.has_key?(status, "worker_count")

      {:status, _pid, _mod, [_pdict, _sys, _parent, _dbg, status_map]} =
        :sys.get_status(pid)

      flat = inspect(status_map)
      refute flat =~ @token
      refute flat =~ @execution_id
      assert flat =~ "redacted" or flat =~ "phase"
    end
  end

  # ---------------------------------------------------------------------------
  # Launch re-authorization / timer / request regressions
  # ---------------------------------------------------------------------------

  describe "delayed launch after record removal" do
    test "stale restart timer does not launch after journal removal", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      # First launch crashes before cleanup; restart is scheduled while entry remains.
      :ok = WorkerScript.reset([:crash_before_receipt])
      receipt_ref = make_ref()
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      # Wait until the first launch has been observed, then remove the intent.
      deadline = System.monotonic_time(:millisecond) + 1_000

      Stream.repeatedly(fn -> length(WorkerScript.starts()) end)
      |> Enum.reduce_while(nil, fn
        n, _ when n >= 1 ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("worker never started")
          else
            Process.sleep(10)
            {:cont, nil}
          end
      end)

      starts_after_first = length(WorkerScript.starts())
      :ok = FakeJournal.remove_exact(@unit_name, @token)

      # Allow restart timer (50ms+) and re-authorization path to run.
      Process.sleep(250)

      assert length(WorkerScript.starts()) == starts_after_first

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     2_000
    end
  end

  describe "delayed launch after same-name record replacement" do
    test "does not launch stale identity when journal row is replaced", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:crash_before_receipt])
      receipt_ref = make_ref()
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      deadline = System.monotonic_time(:millisecond) + 1_000

      Stream.repeatedly(fn -> length(WorkerScript.starts()) end)
      |> Enum.reduce_while(nil, fn
        n, _ when n >= 1 ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("worker never started")
          else
            Process.sleep(10)
            {:cont, nil}
          end
      end)

      starts_after_first = length(WorkerScript.starts())

      replaced = %{
        entry
        | "token" => String.duplicate("e", 64),
          "execution_id" => "exec-replaced",
          "reserved_at_ms" => @reserved_at_ms + 42
      }

      :ok = FakeJournal.replace_entry(@unit_name, replaced)
      Process.sleep(250)

      # Stale delayed launch must not invoke the launcher for the old identity.
      # Replacement under the same name is not autonomously admitted post-ready.
      assert length(WorkerScript.starts()) == starts_after_first
    end
  end

  describe "live worker same-name replacement exclusion" do
    test "hung old worker blocks recover_all replacement until exact DOWN", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:hang, :complete_and_remove])
      entry_ref = make_ref()
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, entry_ref)

      deadline = System.monotonic_time(:millisecond) + 1_000

      Stream.repeatedly(fn -> length(WorkerScript.starts()) end)
      |> Enum.reduce_while(nil, fn
        n, _ when n >= 1 ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("old worker never started")
          else
            Process.sleep(10)
            {:cont, nil}
          end
      end)

      [old_worker] = WorkerScript.worker_pids()
      assert Process.alive?(old_worker)
      assert length(WorkerScript.starts()) == 1

      replaced = %{
        entry
        | "token" => String.duplicate("e", 64),
          "execution_id" => "exec-replaced",
          "reserved_at_ms" => @reserved_at_ms + 42
      }

      :ok = FakeJournal.replace_entry(@unit_name, replaced)
      all_ref = make_ref()
      assert :ok = FakeCoordinator.recover_all(pid, coord, all_ref)

      # While the old recovery worker is live, launcher count stays one and no
      # coordinator completion is emitted for either request.
      Process.sleep(200)
      assert length(WorkerScript.starts()) == 1
      assert Process.alive?(old_worker)

      refute_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^entry_ref},
                     100

      refute_receive {:apple_container_unit_recovery_all_complete, ^pid, ^all_ref}, 50

      # Exact DOWN of the old worker unblocks settlement; replacement is admitted
      # once and only once, then recover_all completes after it finishes.
      true = Process.exit(old_worker, :kill)

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^entry_ref},
                     2_000

      deadline2 = System.monotonic_time(:millisecond) + 2_000

      Stream.repeatedly(fn -> length(WorkerScript.starts()) end)
      |> Enum.reduce_while(nil, fn
        n, _ when n >= 2 ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline2 do
            flunk("replacement worker never admitted: #{inspect(WorkerScript.starts())}")
          else
            Process.sleep(10)
            {:cont, nil}
          end
      end)

      assert_receive {:apple_container_unit_recovery_all_complete, ^pid, ^all_ref}, 2_000
      await_ready(pid)

      assert length(WorkerScript.starts()) == 2
      assert WorkerScript.starts() == [:hang, :complete_and_remove]
      assert FakeJournal.recovery_entries() == {:ok, []}

      refute_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^entry_ref},
                     150

      refute_receive {:apple_container_unit_recovery_all_complete, ^pid, ^all_ref}, 50
    end
  end

  describe "duplicate exact requests" do
    test "duplicate recover_entry produces one notification and one unit start", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:complete_and_remove])
      receipt_ref = make_ref()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     2_000

      refute_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     200

      assert length(WorkerScript.starts()) == 1
    end

    test "exact recover_entry after settlement is idempotent without journal reread or restart",
         %{
           start_reconciler: start,
           coordinator_name: coord,
           entry: entry
         } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:complete_and_remove])
      receipt_ref = make_ref()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     2_000

      await_phase(pid, "ready")
      starts_before = length(WorkerScript.starts())

      # Entry is gone; exact settled replay must still return :ok without IO.
      assert FakeJournal.recovery_entries() == {:ok, []}
      # recovery_entries above bumped load_count; rebaseline after the probe.
      loads_before_replay = FakeJournal.load_count()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      assert FakeJournal.load_count() == loads_before_replay
      assert length(WorkerScript.starts()) == starts_before

      refute_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     200
    end

    test "exact recover_all after settlement is idempotent without journal reread", %{
      start_reconciler: start,
      coordinator_name: coord
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      receipt_ref = make_ref()
      assert :ok = FakeCoordinator.recover_all(pid, coord, receipt_ref)

      assert_receive {:apple_container_unit_recovery_all_complete, ^pid, ^receipt_ref}, 2_000
      await_phase(pid, "ready")

      loads_before_replay = FakeJournal.load_count()
      assert :ok = FakeCoordinator.recover_all(pid, coord, receipt_ref)
      assert FakeJournal.load_count() == loads_before_replay

      refute_receive {:apple_container_unit_recovery_all_complete, ^pid, ^receipt_ref}, 200
    end
  end

  describe "conflicting request ref reuse" do
    test "rejects conflicting recover_entry ref reuse", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:hang])
      receipt_ref = make_ref()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      other = %{
        "unit_name" => @unit_name_b,
        "execution_id" => "exec-rec-2",
        "token" => @token_b,
        "reserved_at_ms" => @reserved_at_ms
      }

      :ok = FakeJournal.set_entries([entry, other])

      assert {:error, :conflicting_request_ref} =
               FakeCoordinator.recover_entry(pid, coord, other, receipt_ref)
    end

    test "rejects conflicting recover_entry ref reuse after settlement", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:complete_and_remove])
      receipt_ref = make_ref()

      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      assert_receive {:apple_container_unit_recovery_entry_complete, ^pid, @unit_name,
                      ^receipt_ref},
                     2_000

      await_phase(pid, "ready")

      other = %{
        "unit_name" => @unit_name_b,
        "execution_id" => "exec-rec-2",
        "token" => @token_b,
        "reserved_at_ms" => @reserved_at_ms
      }

      :ok = FakeJournal.set_entries([other])

      assert {:error, :conflicting_request_ref} =
               FakeCoordinator.recover_entry(pid, coord, other, receipt_ref)

      # Conflict path must not start work for the conflicting identity.
      assert length(WorkerScript.starts()) == 1
    end
  end

  describe "stale retry after ready" do
    test "stale generation-tagged retry does not poll journal or launch", %{
      start_reconciler: start,
      coordinator_name: coord,
      entry: entry
    } do
      :ok = FakeJournal.reset(entries: [])
      assert {:ok, pid} = start.([])
      await_ready(pid)

      :ok = FakeJournal.set_entries([entry])
      :ok = WorkerScript.reset([:crash_before_receipt])
      receipt_ref = make_ref()
      assert :ok = FakeCoordinator.recover_entry(pid, coord, entry, receipt_ref)

      deadline = System.monotonic_time(:millisecond) + 1_000

      Stream.repeatedly(fn -> length(WorkerScript.starts()) end)
      |> Enum.reduce_while(nil, fn
        n, _ when n >= 1 ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("worker never started")
          else
            Process.sleep(10)
            {:cont, nil}
          end
      end)

      # Force settlement to ready while a restart timer from the crash may still be
      # pending with the pre-ready generation.
      :ok = FakeJournal.remove_exact(@unit_name, @token)
      assert :ok = FakeCoordinator.recover_all(pid, coord, make_ref())
      await_ready(pid)

      loads_at_ready = FakeJournal.load_count()
      starts_at_ready = length(WorkerScript.starts())

      # Unknown timer refs and any stale generation retries must be ignored.
      send(pid, {:timeout, make_ref(), {:retry, 0, :load_journal}})
      send(pid, {:timeout, make_ref(), {:retry, 0, {:start_worker, entry}}})
      Process.sleep(200)

      assert FakeJournal.load_count() == loads_at_ready
      assert length(WorkerScript.starts()) == starts_at_ready
    end
  end

  describe "production child_spec sealing" do
    test "production child_spec is sealed and test-only start is explicit" do
      spec = Reconciler.child_spec(:production)
      assert spec.start == {Reconciler, :start_link, [:production]}
      assert spec.shutdown == :infinity

      assert_raise ArgumentError, fn ->
        Reconciler.child_spec({:test_only, []})
      end

      source =
        File.read!(
          Path.expand(
            "../../../lib/arbor/shell/apple_container_unit_recovery_reconciler.ex",
            __DIR__
          )
        )

      assert source =~ "AppleContainerUnitJournal"
      assert source =~ "production_child_args"
      assert source =~ "/usr/local/bin/container"
      # Runtime independence: no implementation imports of port/unit owners.
      refute source =~ "alias Arbor.Shell.PortSession"
      refute source =~ "alias Arbor.Shell.AppleContainerUnitWorker"
      refute source =~ "import Arbor.Shell.AppleContainerUnitDrainCoordinator"
      # Coordinator module name only for registration check.
      assert source =~ "AppleContainerUnitDrainCoordinator"
    end
  end

  # ---------------------------------------------------------------------------
  # Composite supervisor child-loss propagation
  # ---------------------------------------------------------------------------

  describe "composite supervisor child crash propagation" do
    test "reconciler loss exits the composite supervisor" do
      # Isolate names so we do not collide with production atoms when Application
      # later wires them. Exercise the production init shape via a local clone.
      parent = self()

      {:ok, sup} =
        Supervisor.start_link(
          [
            %{
              id: :worker_sup,
              start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
              type: :supervisor,
              restart: :permanent,
              shutdown: :infinity
            },
            %{
              id: :reconciler_probe,
              start: {Agent, :start_link, [fn -> :ok end]},
              restart: :permanent,
              shutdown: :infinity
            }
          ],
          strategy: :one_for_all,
          max_restarts: 0,
          max_seconds: 1
        )

      Process.monitor(sup)
      [_, {_, recon_pid, _, _}] = Supervisor.which_children(sup)
      Process.exit(recon_pid, :kill)

      assert_receive {:DOWN, _, :process, ^sup, _}, 2_000
      refute Process.alive?(sup)
      # parent retained for clarity in failure messages
      assert is_pid(parent)
    end

    test "dynamic supervisor loss exits the composite supervisor" do
      {:ok, sup} =
        Supervisor.start_link(
          [
            %{
              id: :worker_sup,
              start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
              type: :supervisor,
              restart: :permanent,
              shutdown: :infinity
            },
            %{
              id: :reconciler_probe,
              start: {Agent, :start_link, [fn -> :ok end]},
              restart: :permanent,
              shutdown: :infinity
            }
          ],
          strategy: :one_for_all,
          max_restarts: 0,
          max_seconds: 1
        )

      Process.monitor(sup)
      [{_, dyn_pid, _, _}, _] = Supervisor.which_children(sup)
      Process.exit(dyn_pid, :kill)

      assert_receive {:DOWN, _, :process, ^sup, _}, 2_000
      refute Process.alive?(sup)
    end

    test "production supervisor module uses one_for_all with zero restarts" do
      source =
        File.read!(
          Path.expand(
            "../../../lib/arbor/shell/apple_container_unit_recovery_supervisor.ex",
            __DIR__
          )
        )

      assert source =~ "strategy: :one_for_all"
      assert source =~ "max_restarts: 0"
      assert source =~ "shutdown: :infinity"
      assert source =~ "AppleContainerUnitRecoveryWorkerSupervisor"
      assert source =~ "AppleContainerUnitRecoveryReconciler"
    end

    test "production supervisor starts with sealed children when journal empty" do
      # Only when the real production names are free. Skip if already registered.
      if Process.whereis(AppleContainerUnitRecoverySupervisor.name()) ||
           Process.whereis(AppleContainerUnitRecoverySupervisor.worker_supervisor_name()) ||
           Process.whereis(Reconciler) do
        :ok
      else
        # Production reconciler hardcodes AppleContainerUnitJournal which may be
        # disabled without config — still must start closed/retrying, not crash.
        # We only assert supervisor init options via source + child_spec shape.
        spec = AppleContainerUnitRecoverySupervisor.child_spec([])
        assert spec.type == :supervisor
        assert spec.shutdown == :infinity
        assert spec.restart == :permanent
      end
    end
  end
end
