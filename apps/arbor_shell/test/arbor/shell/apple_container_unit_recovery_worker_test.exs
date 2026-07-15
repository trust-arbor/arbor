defmodule Arbor.Shell.AppleContainerUnitRecoveryWorkerTest do
  @moduledoc """
  Independent Apple Container durable-intent recovery worker tests.

  Uses deterministic same-library fakes only — never real `container` commands.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.AppleContainerUnitRecoveryRuntime
  alias Arbor.Shell.AppleContainerUnitRecoveryWorker, as: Worker
  alias Arbor.Shell.ExecutablePolicy.Executable

  @moduletag :fast

  @runtime_path "/usr/local/bin/container"
  @hex32 String.duplicate("a", 32)
  @unit_name "arbor-v1-#{@hex32}"
  @token String.duplicate("b", 64)
  @execution_id "exec-recovery-1"
  @reserved_at_ms 1_700_000_000_000

  @force_stop_args ["kill", "--signal", "KILL", @unit_name]
  @delete_args ["delete", "--force", @unit_name]
  @list_args ["list", "--all", "--format", "json"]

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  defmodule FakeRuntime do
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

    def calls do
      ensure_started()
      GenServer.call(__MODULE__, :calls)
    end

    def run_bound(executable, args, opts)
        when is_list(args) and is_list(opts) do
      ensure_started()

      # Surface raise/exit/throw in the worker process (not the fake GenServer).
      case GenServer.call(__MODULE__, {:run_bound, executable, args, opts}) do
        {:do_raise, exception} -> raise exception
        {:do_exit, reason} -> exit(reason)
        {:do_throw, reason} -> throw(reason)
        other -> other
      end
    end

    @impl true
    def init(_) do
      {:ok, %{script: [], calls: []}}
    end

    @impl true
    def handle_call({:reset, script}, _from, _state) do
      {:reply, :ok, %{script: script, calls: []}}
    end

    def handle_call(:calls, _from, state) do
      {:reply, Enum.reverse(state.calls), state}
    end

    def handle_call({:run_bound, executable, args, opts}, _from, state) do
      call = %{executable: executable, args: args, opts: opts}
      calls = [call | state.calls]

      case state.script do
        [{:ok, result} | rest] when is_map(result) ->
          {:reply, {:ok, result}, %{state | script: rest, calls: calls}}

        [{:error, reason} | rest] ->
          {:reply, {:error, reason}, %{state | script: rest, calls: calls}}

        [{:raise, exception} | rest] ->
          {:reply, {:do_raise, exception}, %{state | script: rest, calls: calls}}

        [{:exit, reason} | rest] ->
          {:reply, {:do_exit, reason}, %{state | script: rest, calls: calls}}

        [{:throw, reason} | rest] ->
          {:reply, {:do_throw, reason}, %{state | script: rest, calls: calls}}

        [] ->
          {:reply, {:error, :script_exhausted}, %{state | calls: calls}}

        other ->
          {:reply, {:error, {:bad_script, other}}, %{state | calls: calls}}
      end
    end
  end

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

    def complete_calls do
      ensure_started()
      GenServer.call(__MODULE__, :complete_calls)
    end

    def complete(unit_name, token, server \\ __MODULE__) do
      case GenServer.call(server, {:complete, unit_name, token}) do
        {:do_raise, exception} -> raise exception
        {:do_exit, reason} -> exit(reason)
        {:do_throw, reason} -> throw(reason)
        other -> other
      end
    end

    @impl true
    def init(_) do
      {:ok, %{results: [], calls: [], expected_unit: nil, expected_token: nil}}
    end

    @impl true
    def handle_call({:reset, opts}, _from, _state) do
      {:reply, :ok,
       %{
         results: Keyword.get(opts, :results, [:ok]),
         calls: [],
         expected_unit: Keyword.get(opts, :expected_unit),
         expected_token: Keyword.get(opts, :expected_token)
       }}
    end

    def handle_call(:complete_calls, _from, state) do
      {:reply, Enum.reverse(state.calls), state}
    end

    def handle_call({:complete, unit_name, token}, _from, state) do
      calls = [{unit_name, token} | state.calls]

      cond do
        is_binary(state.expected_unit) and unit_name != state.expected_unit ->
          {:reply, {:error, :unknown_unit_name}, %{state | calls: calls}}

        is_binary(state.expected_token) and token != state.expected_token ->
          {:reply, {:error, :token_mismatch}, %{state | calls: calls}}

        true ->
          case state.results do
            [{:raise, exception} | rest] ->
              {:reply, {:do_raise, exception}, %{state | results: rest, calls: calls}}

            [{:exit, reason} | rest] ->
              {:reply, {:do_exit, reason}, %{state | results: rest, calls: calls}}

            [{:throw, reason} | rest] ->
              {:reply, {:do_throw, reason}, %{state | results: rest, calls: calls}}

            [result | rest] ->
              {:reply, result, %{state | results: rest, calls: calls}}

            [] ->
              {:reply, {:error, :apple_container_unit_journal_unavailable},
               %{state | calls: calls}}
          end
      end
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    FakeRuntime.ensure_started()
    FakeJournal.ensure_started()
    :ok = FakeRuntime.reset([])
    :ok = FakeJournal.reset()

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

    {:ok, executable: executable, entry: entry}
  end

  defp success(opts \\ %{}) do
    Map.merge(
      %{
        exit_code: 0,
        stdout: "",
        stderr: "",
        duration_ms: 1,
        timed_out: false,
        cancelled: false,
        killed: false,
        output_truncated: false,
        output_limit_exceeded: false
      },
      opts
    )
  end

  defp absent_list do
    success(%{stdout: "[]"})
  end

  defp present_list do
    success(%{
      stdout: Jason.encode!([%{"configuration" => %{"id" => @unit_name}}])
    })
  end

  defp start_worker(entry, executable) do
    receipt_ref = make_ref()

    assert {:ok, worker} =
             Worker.start_for_test(entry, executable, self(), receipt_ref,
               runtime: FakeRuntime,
               journal: FakeJournal,
               journal_server: FakeJournal
             )

    {worker, receipt_ref}
  end

  defp await_receipt(worker, receipt_ref, timeout \\ 2_000) do
    assert_receive {:apple_container_unit_recovered, ^worker, @unit_name, ^receipt_ref}, timeout
  end

  defp refute_receipt(timeout \\ 150) do
    refute_receive {:apple_container_unit_recovered, _, _, _}, timeout
  end

  defp await_exit(worker, timeout \\ 2_000) do
    receive do
      {:EXIT, ^worker, :normal} ->
        :ok
    after
      timeout ->
        flunk("worker #{inspect(worker)} did not exit normally after #{timeout}ms")
    end
  end

  defp await_abnormal_exit(worker, expected_tag, timeout \\ 2_000) do
    receive do
      {:EXIT, ^worker, {^expected_tag, _detail}} ->
        :ok

      {:EXIT, ^worker, other} ->
        flunk("expected #{inspect(expected_tag)} stop, got #{inspect(other)}")
    after
      timeout ->
        if Process.alive?(worker) do
          flunk("worker #{inspect(worker)} still alive after #{timeout}ms")
        else
          :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  describe "successful recovery" do
    test "force-stop -> delete -> exact absence + journal complete emits one receipt", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success(%{exit_code: 0})},
          {:ok, success(%{exit_code: 0})},
          {:ok, absent_list()}
        ])

      :ok =
        FakeJournal.reset(
          results: [:ok],
          expected_unit: @unit_name,
          expected_token: @token
        )

      {worker, receipt_ref} = start_worker(entry, executable)
      await_receipt(worker, receipt_ref)
      await_exit(worker)
      refute_receipt()

      calls = FakeRuntime.calls()
      assert length(calls) == 3

      assert Enum.map(calls, & &1.args) == [
               @force_stop_args,
               @delete_args,
               @list_args
             ]

      for call <- calls do
        assert call.executable.path == @runtime_path
        assert call.opts[:cwd] == "/"
        assert call.opts[:clear_env] == true
        assert call.opts[:env] == %{}
        assert call.opts[:timeout] == 5_000
        assert is_integer(call.opts[:max_output_bytes]) and call.opts[:max_output_bytes] > 0
      end

      assert FakeJournal.complete_calls() == [{@unit_name, @token}]
    end

    test "force-stop and delete failures still reach verification", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success(%{exit_code: 1, timed_out: true})},
          {:ok, success(%{exit_code: 9, containment_failure: true})},
          {:ok, absent_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok], expected_unit: @unit_name, expected_token: @token)

      {worker, receipt_ref} = start_worker(entry, executable)
      await_receipt(worker, receipt_ref)
      await_exit(worker)

      assert Enum.map(FakeRuntime.calls(), & &1.args) == [
               @force_stop_args,
               @delete_args,
               @list_args
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Verification loops without receipt
  # ---------------------------------------------------------------------------

  describe "verification not absent" do
    test "present list retries cleanup and emits no receipt", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()},
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, _receipt_ref} = start_worker(entry, executable)

      # First cleanup cycle + second force-stop after retry timer (50ms).
      Process.sleep(120)
      assert Process.alive?(worker)
      refute_receipt()
      assert FakeJournal.complete_calls() == []

      args_sequence = Enum.map(FakeRuntime.calls(), & &1.args)
      assert length(args_sequence) >= 4

      assert Enum.take(args_sequence, 4) == [
               @force_stop_args,
               @delete_args,
               @list_args,
               @force_stop_args
             ]

      Process.exit(worker, :kill)
    end

    test "malformed and failed verification loops without receipt", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, success(%{stdout: "not-json{"})},
          {:ok, success()},
          {:ok, success()},
          {:ok, success(%{exit_code: 1, stdout: ""})},
          {:ok, success()},
          {:ok, success()},
          {:error, :runtime_operation_failed}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, _} = start_worker(entry, executable)
      Process.sleep(200)
      assert Process.alive?(worker)
      refute_receipt()
      assert FakeJournal.complete_calls() == []

      Process.exit(worker, :kill)
    end
  end

  # ---------------------------------------------------------------------------
  # Journal completion
  # ---------------------------------------------------------------------------

  describe "journal completion" do
    test "journal failure/unavailability retains worker, retries, then succeeds", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, absent_list()}
        ])

      :ok =
        FakeJournal.reset(
          results: [
            {:error, :apple_container_unit_journal_unavailable},
            {:error, {:apple_container_unit_journal_persist_failed, :eio}},
            :ok
          ],
          expected_unit: @unit_name,
          expected_token: @token
        )

      {worker, receipt_ref} = start_worker(entry, executable)

      # First complete attempt fails — no receipt yet.
      Process.sleep(20)
      assert Process.alive?(worker)
      refute_receive {:apple_container_unit_recovered, ^worker, @unit_name, ^receipt_ref}, 30

      await_receipt(worker, receipt_ref, 3_000)
      await_exit(worker)

      assert length(FakeJournal.complete_calls()) == 3
      assert Enum.uniq(FakeJournal.complete_calls()) == [{@unit_name, @token}]
      # Cleanup ran once only — no candidate rework.
      assert length(FakeRuntime.calls()) == 3
    end

    test "transient journal errors retry with bounded delay", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, absent_list()}
        ])

      :ok =
        FakeJournal.reset(
          results: [
            {:error, :apple_container_unit_journal_unavailable},
            {:error, :apple_container_unit_journal_unavailable},
            :ok
          ],
          expected_unit: @unit_name,
          expected_token: @token
        )

      {worker, receipt_ref} = start_worker(entry, executable)
      refute_receive {:apple_container_unit_recovered, ^worker, @unit_name, ^receipt_ref}, 40
      assert Process.alive?(worker)

      await_receipt(worker, receipt_ref, 3_000)
      await_exit(worker)
      assert length(FakeJournal.complete_calls()) == 3
      refute_receipt()
    end

    test "wrong token stops abnormally with no receipt", %{entry: entry, executable: executable} do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, absent_list()}
        ])

      :ok =
        FakeJournal.reset(
          results: [:ok],
          expected_unit: @unit_name,
          expected_token: String.duplicate("f", 64)
        )

      {worker, _ref} = start_worker(entry, executable)
      await_abnormal_exit(worker, :journal_token_rejected)
      refute_receipt()
      assert FakeJournal.complete_calls() == [{@unit_name, @token}]
      refute Process.alive?(worker)
    end

    test "replay unknown unit stops abnormally with no receipt", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, absent_list()}
        ])

      :ok =
        FakeJournal.reset(
          results: [:ok],
          expected_unit: "arbor-v1-" <> String.duplicate("c", 32),
          expected_token: @token
        )

      {worker, _} = start_worker(entry, executable)
      await_abnormal_exit(worker, :journal_token_rejected)
      refute_receipt()
      refute Process.alive?(worker)
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime / journal containment
  # ---------------------------------------------------------------------------

  describe "callback containment" do
    test "runtime exit/error/throw project to containment failure and retry cleanup", %{
      entry: entry,
      executable: executable
    } do
      # Three contained force-stops each advance to delete+verify (present → retry).
      :ok =
        FakeRuntime.reset([
          # cycle 1
          {:exit, :runtime_blew_up},
          {:ok, success()},
          {:ok, present_list()},
          # cycle 2
          {:raise, RuntimeError.exception("runtime boom")},
          {:ok, success()},
          {:ok, present_list()},
          # cycle 3
          {:throw, :runtime_throw},
          {:ok, success()},
          {:ok, present_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, _} = start_worker(entry, executable)

      # Wait through two cleanup retries (50ms then 100ms).
      Process.sleep(250)
      assert Process.alive?(worker)
      refute_receipt()
      assert FakeJournal.complete_calls() == []

      args = Enum.map(FakeRuntime.calls(), & &1.args)
      assert length(args) >= 7
      assert Enum.at(args, 0) == @force_stop_args
      assert Enum.at(args, 1) == @delete_args
      assert Enum.at(args, 2) == @list_args
      assert Enum.at(args, 3) == @force_stop_args

      Process.exit(worker, :kill)
    end

    test "journal exit/error/throw are contained as transient retries", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, absent_list()}
        ])

      :ok =
        FakeJournal.reset(
          results: [
            {:exit, :journal_exit},
            {:raise, RuntimeError.exception("journal boom")},
            {:throw, :journal_throw},
            :ok
          ],
          expected_unit: @unit_name,
          expected_token: @token
        )

      {worker, receipt_ref} = start_worker(entry, executable)
      await_receipt(worker, receipt_ref, 5_000)
      await_exit(worker)
      assert length(FakeJournal.complete_calls()) == 4
      assert length(FakeRuntime.calls()) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Message / timer isolation
  # ---------------------------------------------------------------------------

  describe "message isolation" do
    test "stale/foreign timer and forged receipt messages cannot advance state", %{
      entry: entry,
      executable: executable
    } do
      # Stay alive on present-list cleanup retry — permanent journal rejection
      # now stops the worker abnormally.
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()},
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, receipt_ref} = start_worker(entry, executable)
      Process.sleep(30)
      assert Process.alive?(worker)
      assert FakeJournal.complete_calls() == []
      refute_receipt()
      runtime_calls = length(FakeRuntime.calls())
      assert runtime_calls >= 3

      send(worker, {:timeout, make_ref(), {:run, :force_stop, ["kill"]}})
      send(worker, {:timeout, make_ref(), :journal_complete})
      send(worker, {:apple_container_unit_recovered, self(), @unit_name, receipt_ref})
      send(worker, {:apple_container_unit_recovered, worker, @unit_name, make_ref()})
      send(worker, {:timeout, make_ref(), {:run, :delete, ["delete"]}})

      Process.sleep(50)
      assert Process.alive?(worker)
      refute_receipt()
      # No journal completion from forged messages.
      assert FakeJournal.complete_calls() == []

      Process.exit(worker, :kill)
    end
  end

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  describe "status redaction" do
    test "worker status never leaks token, executable, raw output, or journal server", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, _} = start_worker(entry, executable)
      Process.sleep(30)

      {:status, ^worker, _mod, status_items} = :sys.get_status(worker)
      text = inspect(status_items)

      refute text =~ @token
      refute text =~ @runtime_path
      refute text =~ @execution_id
      refute text =~ "FakeJournal"
      refute text =~ "FakeRuntime"
      refute text =~ String.duplicate("c", 64)
      # unit_name is intentional public recovery identity; token is not.
      assert text =~ ":redacted"

      Process.exit(worker, :kill)
    end
  end

  # ---------------------------------------------------------------------------
  # Sealed production admission
  # ---------------------------------------------------------------------------

  describe "sealed production admission" do
    test "production_child_args builds tagged tuple and child_spec is temporary", %{
      entry: entry,
      executable: executable
    } do
      receipt_ref = make_ref()

      assert {:ok, {:production, ^entry, ^executable, owner, ^receipt_ref} = args} =
               Worker.production_child_args(entry, executable, self(), receipt_ref)

      assert owner == self()

      spec = Worker.child_spec(args)
      assert spec.restart == :temporary
      assert spec.shutdown == :infinity
      assert spec.type == :worker
      assert spec.start == {Worker, :start_link, [args]}
    end

    test "production tagged admission cannot inject modules or maps", %{
      entry: entry,
      executable: executable
    } do
      receipt_ref = make_ref()

      # Arbitrary map injection surface is closed.
      assert {:error, :invalid_recovery_start} =
               Worker.start_link(%{
                 record: entry,
                 executable: executable,
                 owner_pid: self(),
                 receipt_ref: receipt_ref,
                 runtime: FakeRuntime,
                 journal: FakeJournal,
                 journal_server: FakeJournal
               })

      assert_raise ArgumentError, fn ->
        Worker.child_spec(%{
          runtime: FakeRuntime,
          journal: FakeJournal,
          record: entry
        })
      end

      assert_raise ArgumentError, fn ->
        Worker.child_spec(
          {:test_only, entry, executable, self(), receipt_ref,
           runtime: FakeRuntime, journal: FakeJournal, journal_server: FakeJournal}
        )
      end

      # Production start_link hardcodes real runtime/journal — no injection keys.
      assert {:error, :invalid_unit_name} =
               Worker.start_link(
                 {:production,
                  %{
                    "unit_name" => "bad",
                    "execution_id" => @execution_id,
                    "token" => @token,
                    "reserved_at_ms" => @reserved_at_ms
                  }, executable, self(), receipt_ref}
               )

      assert {:error, :invalid_recovery_executable} =
               Worker.start_link(
                 {:production, entry, %{executable | path: "/usr/bin/false"}, self(), receipt_ref}
               )

      # No production start/4 that pretends to be supervised.
      refute function_exported?(Worker, :start, 4)
      assert function_exported?(Worker, :production_child_args, 4)
      assert function_exported?(Worker, :start_for_test, 5)
    end

    test "production_child_args rejects non-pid owner and non-executable", %{
      entry: entry,
      executable: executable
    } do
      assert {:error, :invalid_recovery_start} =
               Worker.production_child_args(entry, executable, :not_a_pid, make_ref())

      assert {:error, :invalid_recovery_start} =
               Worker.production_child_args(entry, :not_executable, self(), make_ref())
    end
  end

  # ---------------------------------------------------------------------------
  # Core / invariant abnormal stop
  # ---------------------------------------------------------------------------

  describe "invariant abnormal stop" do
    test "RecoveryCore.apply_result error stops abnormally with no receipt", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, _} = start_worker(entry, executable)

      # Wait until first force-stop has been applied so core is non-empty.
      Process.sleep(20)
      assert Process.alive?(worker)

      # Force a core invariant: pretend already terminal before next phase applies.
      _ =
        :sys.replace_state(worker, fn state ->
          core = %{
            state.core
            | stage: :terminal,
              cleanup_step: nil,
              terminal: :reconciled
          }

          %{state | core: core}
        end)

      # Advance the pending retry or next phase if still mid-cycle; otherwise
      # inject the next force-stop effect via a synthetic cleanup timer payload
      # matching current timer identity is hard — instead run another cycle by
      # waiting for the natural present-list retry path after first cycle.
      #
      # If the first cycle already completed verify, a retry_after timer is set.
      # Corrupting core to terminal makes the next apply_result fail closed.
      Process.sleep(120)
      await_abnormal_exit(worker, :recovery_invariant_failed)
      refute_receipt()
      assert FakeJournal.complete_calls() == []
      refute Process.alive?(worker)
    end

    test "unexpected effect stops abnormally with no receipt", %{
      entry: entry,
      executable: executable
    } do
      :ok =
        FakeRuntime.reset([
          {:ok, success()},
          {:ok, success()},
          {:ok, present_list()}
        ])

      :ok = FakeJournal.reset(results: [:ok])

      {worker, _} = start_worker(entry, executable)
      Process.sleep(30)
      assert Process.alive?(worker)

      # Replace the scheduled retry effect with an unknown effect shape.
      _ =
        :sys.replace_state(worker, fn state ->
          case state.cleanup_timer do
            timer_ref when is_reference(timer_ref) ->
              _ = :erlang.cancel_timer(timer_ref)

              receive do
                {:timeout, ^timer_ref, _} -> :ok
              after
                0 -> :ok
              end

              new_ref = :erlang.start_timer(10, worker, {:bogus_effect, :not_allowed})

              %{
                state
                | cleanup_timer: new_ref,
                  cleanup_timer_effect: {:bogus_effect, :not_allowed}
              }

            _ ->
              new_ref = :erlang.start_timer(10, worker, {:bogus_effect, :not_allowed})

              %{
                state
                | cleanup_timer: new_ref,
                  cleanup_timer_effect: {:bogus_effect, :not_allowed}
              }
          end
        end)

      await_abnormal_exit(worker, :recovery_invariant_failed)
      refute_receipt()
      assert FakeJournal.complete_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # Architecture regression
  # ---------------------------------------------------------------------------

  describe "architecture regression" do
    test "production recovery runtime calls Executor.run_bound and has no PortSession dependency" do
      runtime_src =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_unit_recovery_runtime.ex",
          __DIR__
        )

      worker_src =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_unit_recovery_worker.ex",
          __DIR__
        )

      assert File.exists?(runtime_src)
      assert File.exists?(worker_src)

      runtime_source = strip_docs_and_comments(File.read!(runtime_src))
      worker_source = strip_docs_and_comments(File.read!(worker_src))

      assert runtime_source =~ "Executor.run_bound"
      refute runtime_source =~ "PortSession"
      refute runtime_source =~ "PortSessionSupervisor"
      refute runtime_source =~ "System.cmd"
      refute runtime_source =~ "start_supervised"

      refute worker_source =~ "PortSession"
      refute worker_source =~ "PortSessionSupervisor"
      refute worker_source =~ "System.cmd"
      refute worker_source =~ "UnitWorker"
      refute worker_source =~ "DrainCoordinator"
      assert worker_source =~ "AppleContainerUnitRecoveryRuntime"
      assert worker_source =~ "AppleContainerUnitJournal"

      # Sealed production tuple hardcodes real modules; test seam is distinct.
      assert worker_source =~ "def production_child_args("
      assert worker_source =~ ":production"
      assert worker_source =~ ":test_only"
      assert worker_source =~ "def start_for_test("
      assert worker_source =~ "runtime: AppleContainerUnitRecoveryRuntime"
      assert worker_source =~ "journal: AppleContainerUnitJournal"
      refute worker_source =~ "def start("

      # Module is loadable and exports the bound entrypoint.
      assert function_exported?(AppleContainerUnitRecoveryRuntime, :run_bound, 3)
    end
  end

  defp strip_docs_and_comments(source) when is_binary(source) do
    source
    |> String.replace(~r/@moduledoc\s+"""[\s\S]*?"""/m, "")
    |> String.replace(~r/@doc\s+"""[\s\S]*?"""/m, "")
    |> String.replace(~r/#.*$/m, "")
  end
end
