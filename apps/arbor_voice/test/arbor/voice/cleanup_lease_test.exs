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
          send(test_pid, {:owner_down_cleanup, Process.alive?(worker)})
          :ok
        end

        opts = [
          supervisor: lease_supervisor,
          cleanup_supervisor: cleanup_supervisor,
          cleanup_per_attempt_timeout_ms: 100,
          retry_base_ms: 5,
          retry_max_ms: 25
        ]

        {:ok, lease, credential} = CleanupLease.start(self(), {:route, cleanup}, opts)
        send(test_pid, {:owner_ready, lease, credential})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_ready, lease, credential}, 500
    lease_ref = Process.monitor(lease)
    assert :ok = CleanupLease.bind_worker(credential, worker)

    Process.exit(owner, :kill)

    assert_receive {:owner_down_cleanup, false}, 1_000
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

  test "a forged credential cannot mutate or inspect the lease", %{opts: opts} do
    assert {:ok, lease, _credential} = CleanupLease.start(self(), nil, opts)
    forged = Redacted.new({lease, make_ref()})

    assert {:error, :lease_unavailable} = CleanupLease.status(forged)

    assert {:error, :lease_unavailable} =
             CleanupLease.register_cleanup(forged, :forged, fn -> :ok end)
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
