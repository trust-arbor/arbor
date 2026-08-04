defmodule Arbor.Voice.CleanupLeaseTest do
  use ExUnit.Case, async: false

  alias Arbor.Voice.CleanupLease
  alias Arbor.Voice.Redacted

  @moduletag :fast

  setup do
    lease_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_restarts: 100})

    cleanup_supervisor = start_supervised!({Task.Supervisor, max_restarts: 100})

    opts = [
      supervisor: lease_supervisor,
      cleanup_supervisor: cleanup_supervisor,
      cleanup_per_attempt_timeout_ms: 100,
      retry_base_ms: 5,
      retry_max_ms: 25,
      max_cleanups: 8
    ]

    {:ok, lease_supervisor: lease_supervisor, cleanup_supervisor: cleanup_supervisor, opts: opts}
  end

  test "initial cleanup is positively retained before any worker is bound", %{opts: opts} do
    cleanup = fn -> :ok end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)
    assert Process.alive?(lease)
    assert inspect(credential) == "#Redacted<>"

    assert {:ok,
            %{
              cleanup_count: 1,
              mode: :holding,
              worker_alive: false,
              cleanup_active: false
            }} = CleanupLease.status(credential)
  end

  test "settle_cleanup discharges one key while a bound worker stays live", %{opts: opts} do
    test_pid = self()
    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    turn_cleanup = fn ->
      send(test_pid, :turn_settled)
      :ok
    end

    route_cleanup = fn ->
      send(test_pid, :route_settled)
      :ok
    end

    assert {:ok, lease, credential} =
             CleanupLease.start(
               self(),
               %{turn: turn_cleanup, route: route_cleanup},
               opts
             )

    on_exit(fn ->
      if Process.alive?(lease), do: Process.exit(lease, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert :ok = CleanupLease.bind_worker(credential, worker)
    assert :ok = CleanupLease.settle_cleanup(credential, :turn, 1_000)
    assert_receive :turn_settled, 500
    refute_receive :route_settled, 50

    assert {:ok,
            %{
              cleanup_count: 1,
              mode: :holding,
              worker_alive: true,
              cleanup_active: false,
              retry_scheduled: false
            }} = CleanupLease.status(credential)

    assert Process.alive?(worker)
    assert :ok = CleanupLease.await_empty(credential, [:turn], 0)
    assert {:error, :cleanup_pending} = CleanupLease.await_empty(credential, [:route], 0)

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 500
    assert_receive :route_settled, 1_000
    assert :ok = CleanupLease.await_empty(credential, [:route], 500)
  end

  test "asynchronous settle and await requests preserve owner-bound lease semantics", %{
    opts: opts
  } do
    worker = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, lease, credential} =
             CleanupLease.start(self(), {:turn, fn -> :ok end}, opts)

    on_exit(fn ->
      if Process.alive?(lease), do: Process.exit(lease, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert :ok = CleanupLease.bind_worker(credential, worker)
    assert {:ok, settle_request} = CleanupLease.settle_cleanup_request(credential, :turn, 500)
    assert_receive settle_response, 1_000
    assert {:reply, :ok} = CleanupLease.check_response(settle_response, settle_request)

    assert {:ok, await_request} = CleanupLease.await_empty_request(credential, [:turn], 0)
    assert_receive await_response, 500
    assert {:reply, :ok} = CleanupLease.check_response(await_response, await_request)
    assert :no_reply = CleanupLease.check_response(:unrelated, await_request)
  end

  test "failed settlement remains holding without retry until worker DOWN", %{opts: opts} do
    test_pid = self()
    attempts = :atomics.new(1, signed: false)
    worker = spawn(fn -> Process.sleep(:infinity) end)

    cleanup = fn ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(test_pid, {:settlement_attempt, attempt})
      if attempt == 1, do: {:error, :revoke_failed}, else: :ok
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:turn, cleanup}, opts)

    on_exit(fn ->
      if Process.alive?(lease), do: Process.exit(lease, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert :ok = CleanupLease.bind_worker(credential, worker)
    assert {:error, :cleanup_pending} = CleanupLease.settle_cleanup(credential, :turn, 500)
    assert_receive {:settlement_attempt, 1}, 500

    assert {:ok,
            %{
              cleanup_count: 1,
              mode: :holding,
              worker_alive: true,
              cleanup_active: false,
              retry_scheduled: false
            }} = CleanupLease.status(credential)

    refute_receive {:settlement_attempt, 2}, 100

    Process.exit(worker, :kill)
    assert_receive {:settlement_attempt, 2}, 1_000
    assert :ok = CleanupLease.await_empty(credential, [:turn], 500)
  end

  test "settlement timeout is capped by cleanup configuration and retained", %{opts: opts} do
    test_pid = self()
    attempts = :atomics.new(1, signed: false)
    worker = spawn(fn -> Process.sleep(:infinity) end)
    opts = Keyword.put(opts, :cleanup_per_attempt_timeout_ms, 30)

    cleanup = fn ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(test_pid, {:timed_settlement_attempt, attempt, self()})
      if attempt == 1, do: Process.sleep(:infinity), else: :ok
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:turn, cleanup}, opts)

    on_exit(fn ->
      if Process.alive?(lease), do: Process.exit(lease, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert :ok = CleanupLease.bind_worker(credential, worker)
    started_at = System.monotonic_time(:millisecond)
    assert {:error, :cleanup_pending} = CleanupLease.settle_cleanup(credential, :turn, 1_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert_receive {:timed_settlement_attempt, 1, first_pid}, 500
    refute Process.alive?(first_pid)
    assert elapsed_ms < 800
    refute_receive {:timed_settlement_attempt, 2, _pid}, 100

    assert {:ok, %{cleanup_count: 1, mode: :holding, retry_scheduled: false}} =
             CleanupLease.status(credential)

    Process.exit(worker, :kill)
    assert_receive {:timed_settlement_attempt, 2, _pid}, 1_000
    assert :ok = CleanupLease.await_empty(credential, [:turn], 500)
  end

  test "settle_cleanup resolves a provisional obligation by its logical key", %{opts: opts} do
    test_pid = self()
    worker = spawn(fn -> Process.sleep(:infinity) end)

    cleanup = fn ->
      send(test_pid, :provisional_settled)
      :ok
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), nil, opts)

    on_exit(fn ->
      if Process.alive?(lease), do: Process.exit(lease, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert :ok = CleanupLease.adopt_provisional_cleanup(credential, :turn, cleanup)
    assert :ok = CleanupLease.bind_worker(credential, worker)
    assert :ok = CleanupLease.settle_cleanup(credential, :turn, 500)
    assert_receive :provisional_settled, 500

    assert {:ok, %{cleanup_count: 0, mode: :holding, worker_alive: true}} =
             CleanupLease.status(credential)

    assert :ok = CleanupLease.await_empty(credential, [:turn], 0)
  end

  test "owner death during settlement retires the worker and drains the retained key", %{
    lease_supervisor: lease_supervisor,
    cleanup_supervisor: cleanup_supervisor
  } do
    test_pid = self()
    attempts = :atomics.new(1, signed: false)

    cleanup = fn ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(test_pid, {:owner_death_settlement_attempt, attempt, self()})
      if attempt == 1, do: Process.sleep(:infinity), else: :ok
    end

    owner =
      spawn(fn ->
        worker = spawn(fn -> Process.sleep(:infinity) end)

        opts = [
          supervisor: lease_supervisor,
          cleanup_supervisor: cleanup_supervisor,
          cleanup_per_attempt_timeout_ms: 1_000,
          retry_base_ms: 5,
          retry_max_ms: 25
        ]

        {:ok, lease, credential} = CleanupLease.start(self(), {:turn, cleanup}, opts)
        :ok = CleanupLease.bind_worker(credential, worker)
        send(test_pid, {:settlement_owner_ready, lease, worker})
        result = CleanupLease.settle_cleanup(credential, :turn, 2_000)
        send(test_pid, {:settlement_owner_result, result})
      end)

    assert_receive {:settlement_owner_ready, lease, worker}, 500
    assert_receive {:owner_death_settlement_attempt, 1, first_cleanup_pid}, 500

    owner_ref = Process.monitor(owner)
    lease_ref = Process.monitor(lease)
    worker_ref = Process.monitor(worker)
    first_cleanup_ref = Process.monitor(first_cleanup_pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^first_cleanup_ref, :process, ^first_cleanup_pid, _reason}, 1_000
    assert_receive {:owner_death_settlement_attempt, 2, _retry_pid}, 1_000
    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :normal}, 1_000
    refute_receive {:settlement_owner_result, _result}, 50
  end

  test "settle_cleanup rejects unknown, oversized, and duplicate requests", %{opts: opts} do
    test_pid = self()
    worker = spawn(fn -> Process.sleep(:infinity) end)

    cleanup = fn ->
      send(test_pid, {:serialized_settlement_started, self()})

      receive do
        :finish_serialized_settlement -> :ok
      end
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:turn, cleanup}, opts)

    on_exit(fn ->
      if Process.alive?(lease), do: Process.exit(lease, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert :ok = CleanupLease.bind_worker(credential, worker)
    assert {:error, :unknown_cleanup_key} = CleanupLease.settle_cleanup(credential, :missing, 50)

    assert {:error, :invalid_cleanup_request} =
             CleanupLease.settle_cleanup(credential, String.duplicate("k", 4_097), 50)

    assert {:error, :invalid_cleanup_request} =
             CleanupLease.settle_cleanup(credential, :turn, 60_001)

    {^lease, token} = Redacted.value(credential)
    reply_tag = make_ref()

    send(
      lease,
      {:"$gen_call", {self(), reply_tag}, {:settle_cleanup, token, :turn, 500}}
    )

    assert_receive {:serialized_settlement_started, cleanup_pid}, 500

    assert {:error, :cleanup_busy} =
             CleanupLease.settle_cleanup(credential, :turn, 50)

    send(cleanup_pid, :finish_serialized_settlement)
    assert_receive {^reply_tag, :ok}, 500
    assert :ok = CleanupLease.await_empty(credential, [:turn], 0)
  end

  test "cleanup is retained until exact success and cleanup worker DOWN", %{opts: opts} do
    test_pid = self()

    cleanup = fn ->
      send(test_pid, {:cleanup_started, self()})

      receive do
        :finish_cleanup -> :ok
      end
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:turn, cleanup}, opts)
    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    assert_receive {:cleanup_started, cleanup_pid}, 500

    assert {:ok, %{cleanup_count: 1, cleanup_active: true}} = CleanupLease.status(credential)

    %{current: %{generation: generation, pid: ^cleanup_pid}} = :sys.get_state(lease)

    send(
      lease,
      {:cleanup_result, generation, cleanup_pid, :ok, System.monotonic_time(:millisecond)}
    )

    assert {:ok, %{cleanup_count: 1, cleanup_active: true}} = CleanupLease.status(credential)

    send(cleanup_pid, :finish_cleanup)
    assert :ok = CleanupLease.await_empty(credential, [:turn], 500)
    assert {:ok, %{cleanup_count: 0, cleanup_active: false}} = CleanupLease.status(credential)
  end

  test "owner death retires the bound worker before cleanup executes", %{
    lease_supervisor: lease_supervisor,
    cleanup_supervisor: cleanup_supervisor
  } do
    test_pid = self()
    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    owner =
      spawn(fn ->
        cleanup = fn ->
          send(test_pid, {:owner_down_cleanup, Process.alive?(worker), self()})

          receive do
            :finish_owner_down_cleanup -> :ok
          end
        end

        opts = [
          supervisor: lease_supervisor,
          cleanup_supervisor: cleanup_supervisor,
          cleanup_per_attempt_timeout_ms: 100,
          retry_base_ms: 5,
          retry_max_ms: 25
        ]

        {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)
        :ok = CleanupLease.bind_worker(credential, worker)
        send(test_pid, {:owner_ready, lease, credential})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_ready, lease, credential}, 500
    lease_ref = Process.monitor(lease)

    Process.exit(owner, :kill)

    assert_receive {:owner_down_cleanup, false, cleanup_pid}, 1_000
    assert Process.alive?(lease)
    assert {:error, :lease_unavailable} = CleanupLease.status(credential)

    send(cleanup_pid, :finish_owner_down_cleanup)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :normal}, 1_000
  end

  test "a stale result cannot discharge a live replacement generation", %{opts: opts} do
    test_pid = self()
    attempts = :atomics.new(1, signed: false)
    gate = :atomics.new(1, signed: false)

    cleanup = fn ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(test_pid, {:stale_attempt, attempt, self()})

      wait_until(fn -> :atomics.get(gate, 1) == 1 end)
      :ok
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      if Process.alive?(lease), do: Process.exit(lease, :kill)
    end)

    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    assert_receive {:stale_attempt, 1, first_pid}, 500

    %{current: %{generation: first_generation}} = :sys.get_state(lease)
    Process.exit(first_pid, :kill)

    assert_receive {:stale_attempt, 2, second_pid}, 1_000
    refute second_pid == first_pid

    send(
      lease,
      {:cleanup_result, first_generation, first_pid, :ok, System.monotonic_time(:millisecond)}
    )

    assert {:ok, %{cleanup_count: 1, cleanup_active: true}} = CleanupLease.status(credential)

    :atomics.put(gate, 1, 1)
    assert :ok = CleanupLease.await_empty(credential, [:route], 1_000)
  end

  test "copied success plus abnormal task DOWN cannot discharge its generation", %{opts: opts} do
    test_pid = self()
    attempts = :atomics.new(1, signed: false)
    gate = :atomics.new(1, signed: false)

    cleanup = fn ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(test_pid, {:abnormal_down_attempt, attempt, self()})
      wait_until(fn -> :atomics.get(gate, 1) == 1 end)
      :ok
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      if Process.alive?(lease), do: Process.exit(lease, :kill)
    end)

    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    assert_receive {:abnormal_down_attempt, 1, first_pid}, 500

    %{current: %{generation: generation, pid: ^first_pid}} = :sys.get_state(lease)

    send(
      lease,
      {:cleanup_result, generation, first_pid, :ok, System.monotonic_time(:millisecond)}
    )

    Process.exit(first_pid, :kill)

    assert_receive {:abnormal_down_attempt, 2, second_pid}, 1_000
    refute second_pid == first_pid
    assert {:ok, %{cleanup_count: 1, cleanup_active: true}} = CleanupLease.status(credential)

    :atomics.put(gate, 1, 1)
    assert :ok = CleanupLease.await_empty(credential, [:route], 1_000)
  end

  test "a hanging first cleanup cannot starve a later key", %{opts: opts} do
    test_pid = self()
    recover = :atomics.new(1, signed: false)
    first_attempts = :atomics.new(1, signed: false)

    first = fn ->
      attempt = :atomics.add_get(first_attempts, 1, 1)
      send(test_pid, {:first_cleanup_started, attempt})

      if :atomics.get(recover, 1) == 1 do
        :ok
      else
        Process.sleep(:infinity)
      end
    end

    later = fn ->
      send(test_pid, :later_cleanup_ran)
      :ok
    end

    assert {:ok, lease, credential} =
             CleanupLease.start(self(), %{first: first, later: later}, opts)

    on_exit(fn ->
      :atomics.put(recover, 1, 1)
      if Process.alive?(lease), do: Process.exit(lease, :kill)
    end)

    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    assert_receive {:first_cleanup_started, 1}, 500
    assert_receive :later_cleanup_ran, 1_000
    assert :ok = CleanupLease.await_empty(credential, [:later], 500)

    :atomics.put(recover, 1, 1)
    assert :ok = CleanupLease.await_empty(credential, [:first], 1_000)
  end

  test "cleanup supervisor outage retains obligations and recovers by name", %{
    lease_supervisor: lease_supervisor
  } do
    name = __MODULE__.RecoverableCleanupSupervisor
    stop_named_supervisor(name)

    {:ok, cleanup_supervisor} = Task.Supervisor.start_link(name: name)
    Process.unlink(cleanup_supervisor)

    on_exit(fn -> stop_named_supervisor(name) end)

    test_pid = self()

    cleanup = fn ->
      send(test_pid, :recovered_cleanup)
      :ok
    end

    opts = [
      supervisor: lease_supervisor,
      cleanup_supervisor: name,
      cleanup_per_attempt_timeout_ms: 50,
      retry_base_ms: 10,
      retry_max_ms: 20
    ]

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)
    Process.exit(cleanup_supervisor, :kill)
    wait_until(fn -> Process.whereis(name) == nil end)

    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    refute_receive :recovered_cleanup, 100
    assert {:ok, %{cleanup_count: 1}} = CleanupLease.status(credential)

    {:ok, replacement} = Task.Supervisor.start_link(name: name)
    Process.unlink(replacement)

    assert_receive :recovered_cleanup, 1_000
    assert :ok = CleanupLease.await_empty(credential, [:route], 500)
    assert Process.alive?(lease)
  end

  test "killing the lease kills its in-flight supervised cleanup child", %{opts: opts} do
    test_pid = self()

    cleanup = fn ->
      send(test_pid, {:orphan_probe_started, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)
    lease_ref = Process.monitor(lease)
    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    assert_receive {:orphan_probe_started, cleanup_pid}, 500
    cleanup_ref = Process.monitor(cleanup_pid)

    Process.exit(lease, :kill)

    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :killed}, 500
    assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup_pid, _reason}, 500
  end

  test "genuine credentials are owner-process bound", %{opts: opts} do
    assert {:ok, _lease, credential} = CleanupLease.start(self(), nil, opts)

    results =
      Task.async(fn ->
        worker = spawn(fn -> Process.sleep(:infinity) end)

        results = %{
          status: CleanupLease.status(credential),
          bind: CleanupLease.bind_worker(credential, worker),
          register: CleanupLease.register_cleanup(credential, :foreign, fn -> :ok end),
          adopt: CleanupLease.adopt_provisional_cleanup(credential, :foreign, fn -> :ok end),
          remove: CleanupLease.remove_cleanup(credential, :foreign),
          begin: CleanupLease.begin_cleanup(credential, :fenced),
          settle: CleanupLease.settle_cleanup(credential, :foreign, 10),
          await: CleanupLease.await_empty(credential, [], 0)
        }

        Process.exit(worker, :kill)
        results
      end)
      |> Task.await()

    assert Enum.all?(Map.values(results), &(&1 == {:error, :lease_unavailable}))

    assert {:ok, %{cleanup_count: 0, mode: :holding, worker_alive: false}} =
             CleanupLease.status(credential)
  end

  test "killing the lease kills a live bound backend worker", %{opts: opts} do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    assert {:ok, lease, credential} = CleanupLease.start(self(), nil, opts)
    lease_ref = Process.monitor(lease)
    assert :ok = CleanupLease.bind_worker(credential, worker)

    Process.exit(lease, :kill)

    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :killed}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 500
  end

  test "cleanup lease supervisor loss terminates the lease and bound worker", %{
    lease_supervisor: lease_supervisor,
    cleanup_supervisor: cleanup_supervisor
  } do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    worker_ref = Process.monitor(worker)

    opts = [
      supervisor: lease_supervisor,
      cleanup_supervisor: cleanup_supervisor,
      cleanup_per_attempt_timeout_ms: 100,
      retry_base_ms: 5,
      retry_max_ms: 25
    ]

    assert {:ok, lease, credential} = CleanupLease.start(self(), nil, opts)
    lease_ref = Process.monitor(lease)
    assert :ok = CleanupLease.bind_worker(credential, worker)

    Process.exit(lease_supervisor, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 500

    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :killed}, 500
  end

  test "lease supervisor child count and waiter inputs are bounded", %{opts: opts} do
    child_spec = Arbor.Voice.CleanupLeaseSupervisor.child_spec([])
    {DynamicSupervisor, :start_link, [supervisor_opts]} = child_spec.start
    assert supervisor_opts[:max_children] == 256

    cleanup = fn -> Process.sleep(:infinity) end
    assert {:ok, _lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)

    assert {:error, :lease_unavailable} =
             CleanupLease.await_empty(credential, [:route], 65_001)

    oversized_keys = Enum.map(1..66, &{:cleanup, &1})

    assert {:error, :lease_unavailable} =
             CleanupLease.await_empty(credential, oversized_keys, 0)
  end

  test "unexpected bound-worker DOWN drains retained cleanup without owner intervention", %{
    opts: opts
  } do
    test_pid = self()
    worker = spawn(fn -> Process.sleep(:infinity) end)

    cleanup = fn ->
      send(test_pid, :worker_down_cleanup)
      :ok
    end

    assert {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)
    assert :ok = CleanupLease.bind_worker(credential, worker)
    assert {:error, :worker_active} = CleanupLease.begin_cleanup(credential, :fenced)

    Process.exit(worker, :kill)

    assert_receive :worker_down_cleanup, 1_000
    assert :ok = CleanupLease.await_empty(credential, [:route], 500)

    assert {:ok, %{cleanup_count: 0, mode: :draining, worker_alive: false}} =
             CleanupLease.status(credential)

    assert Process.alive?(lease)
  end

  test "provisional adoption coalesces an exact ordinary cleanup", %{opts: opts} do
    test_pid = self()

    cleanup = fn ->
      send(test_pid, :coalesced_cleanup)
      :ok
    end

    assert {:ok, _lease, credential} = CleanupLease.start(self(), nil, opts)
    assert :ok = CleanupLease.register_cleanup(credential, :turn, cleanup)
    assert :ok = CleanupLease.adopt_provisional_cleanup(credential, :turn, cleanup)
    assert {:ok, %{cleanup_count: 1}} = CleanupLease.status(credential)

    assert :ok = CleanupLease.begin_cleanup(credential, :fenced)
    assert :ok = CleanupLease.await_empty(credential, [:turn], 500)
    assert_receive :coalesced_cleanup, 500
    refute_receive :coalesced_cleanup, 100
  end

  test "provisional adoption retains one reserved slot beyond ordinary capacity", %{opts: opts} do
    opts = Keyword.put(opts, :max_cleanups, 1)
    ordinary = fn -> :ok end
    provisional = fn -> :ok end

    assert {:ok, _lease, credential} = CleanupLease.start(self(), {:route, ordinary}, opts)

    assert {:error, :cleanup_capacity_exceeded} =
             CleanupLease.register_cleanup(credential, :ordinary_overflow, fn -> :ok end)

    assert :ok = CleanupLease.adopt_provisional_cleanup(credential, :turn, provisional)
    assert {:ok, %{cleanup_count: 2}} = CleanupLease.status(credential)
  end

  test "provisional storage remains visible through its caller-facing logical key", %{opts: opts} do
    provisional = fn -> :ok end

    assert {:ok, _lease, credential} = CleanupLease.start(self(), nil, opts)
    assert :ok = CleanupLease.adopt_provisional_cleanup(credential, :turn, provisional)
    assert {:ok, %{cleanup_count: 1}} = CleanupLease.status(credential)

    assert {:error, :cleanup_pending} = CleanupLease.await_empty(credential, [:turn], 0)
    assert :ok = CleanupLease.remove_cleanup(credential, :turn)
    assert :ok = CleanupLease.await_empty(credential, [:turn], 0)
    assert {:ok, %{cleanup_count: 0}} = CleanupLease.status(credential)
  end

  test "a forged credential cannot mutate or inspect the lease", %{opts: opts} do
    assert {:ok, lease, _credential} = CleanupLease.start(self(), nil, opts)
    forged = Redacted.new({lease, make_ref()})

    assert {:error, :lease_unavailable} = CleanupLease.status(forged)

    assert {:error, :lease_unavailable} =
             CleanupLease.register_cleanup(forged, :forged, fn -> :ok end)

    assert {:error, :lease_unavailable} =
             CleanupLease.settle_cleanup(forged, :forged, 10)
  end

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(_predicate, 0), do: flunk("condition did not converge")

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp stop_named_supervisor(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          500 -> :ok
        end

      nil ->
        :ok
    end
  end
end
