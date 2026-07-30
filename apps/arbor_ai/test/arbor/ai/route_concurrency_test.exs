defmodule Arbor.AI.RouteConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.RouteConcurrency

  # Former finite acquire timeout that made admit-after-timeout indeterminate.
  @former_finite_timeout_ms 1_000

  setup do
    name = :"route_concurrency_gs_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {RouteConcurrency,
         name: name,
         limits: %{
           provider_a: %{arbor: 1},
           provider_b: %{arbor: 2, acp: 0}
         }}
      )

    %{server: name, pid: pid}
  end

  test "acquire stores exact authority PID; name rebinding cannot divert release", %{
    server: name,
    pid: pid_a
  } do
    opts = [route_concurrency_server: name]

    assert {:ok, {:route_concurrency_lease, ^pid_a, token} = lease} =
             RouteConcurrency.acquire(:provider_a, :arbor, opts)

    assert is_reference(token)
    assert is_pid(pid_a)

    # Rebind the registered name to a different authority process while pid_a lives.
    true = Process.unregister(name)

    {:ok, pid_b} =
      GenServer.start_link(RouteConcurrency, [limits: %{provider_a: %{arbor: 1}}], name: name)

    on_exit(fn ->
      if Process.alive?(pid_b) do
        try do
          GenServer.stop(pid_b, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert pid_b != pid_a
    assert Process.whereis(name) == pid_b

    # Release must free capacity on the original PID, not the rebound name.
    assert :ok = RouteConcurrency.release(lease)

    assert {:ok, snap_a} = RouteConcurrency.snapshot(route_concurrency_server: pid_a)
    assert snap_a[{"provider_a", "arbor"}].concurrency_in_use == 0

    # Original authority can admit again; rebound server was never holding the lease.
    assert {:ok, lease_a2} =
             RouteConcurrency.acquire(:provider_a, :arbor, route_concurrency_server: pid_a)

    assert {:ok, {:route_concurrency_lease, ^pid_b, _}} =
             RouteConcurrency.acquire(:provider_a, :arbor, route_concurrency_server: name)

    assert :ok = RouteConcurrency.release(lease_a2)
  end

  test "acquire waits past former finite timeout when authority is suspended (infinity call)", %{
    server: name,
    pid: pid
  } do
    # Behavioral lock: acquire uses :infinity. Suspend past the old 1s timeout,
    # resume, and the caller still receives a lease (not :unavailable).
    # Always resume on cleanup so assertion failures cannot leave the authority suspended.
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    task =
      Task.async(fn ->
        RouteConcurrency.acquire(:provider_a, :arbor, route_concurrency_server: name)
      end)

    try do
      # Still blocked after the former finite timeout window.
      assert Task.yield(task, @former_finite_timeout_ms + 100) == nil

      :ok = :sys.resume(pid)

      assert {:ok, {:route_concurrency_lease, ^pid, _token} = lease} = Task.await(task, 500)
      assert :ok = RouteConcurrency.release(lease)
    after
      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  test "acquire returns opaque lease bound to the authority PID", %{server: server, pid: pid} do
    opts = [route_concurrency_server: server]

    assert {:ok, {:route_concurrency_lease, ^pid, token} = lease} =
             RouteConcurrency.acquire(:provider_a, :arbor, opts)

    assert is_reference(token)

    assert {:error, :at_capacity} = RouteConcurrency.acquire("provider_a", "arbor", opts)

    # release/1 uses the PID bound into the lease (not production default / rebound name).
    assert :ok = RouteConcurrency.release(lease)
    assert :ok = RouteConcurrency.release(lease)

    assert {:ok, _lease2} = RouteConcurrency.acquire(:provider_a, :arbor, opts)
  end

  test "custom server lease never releases against production default", %{server: server} do
    opts = [route_concurrency_server: server]
    assert {:ok, lease} = RouteConcurrency.acquire(:provider_a, :arbor, opts)

    # Capacity still held on the custom server after a forged default-targeted release shape.
    assert :ok = RouteConcurrency.release(:not_a_lease)
    assert {:error, :at_capacity} = RouteConcurrency.acquire(:provider_a, :arbor, opts)

    assert :ok = RouteConcurrency.release(lease)
    assert {:ok, _} = RouteConcurrency.acquire(:provider_a, :arbor, opts)
  end

  test "zero limit and unconfigured routes", %{server: server} do
    opts = [route_concurrency_server: server]

    assert {:error, :at_capacity} = RouteConcurrency.acquire(:provider_b, :acp, opts)
    assert {:error, :unconfigured_route} = RouteConcurrency.acquire(:missing, :arbor, opts)
    assert {:error, :malformed_route} = RouteConcurrency.acquire("", :arbor, opts)
  end

  test "simultaneous callers: second blocked at capacity", %{server: server} do
    opts = [route_concurrency_server: server]
    parent = self()

    task1 =
      Task.async(fn ->
        assert {:ok, lease} = RouteConcurrency.acquire(:provider_a, :arbor, opts)
        send(parent, {:held, self()})

        receive do
          :release -> RouteConcurrency.release(lease)
        end

        :ok
      end)

    assert_receive {:held, holder}, 500

    task2 =
      Task.async(fn ->
        RouteConcurrency.acquire(:provider_a, :arbor, opts)
      end)

    assert {:error, :at_capacity} = Task.await(task2, 500)

    send(holder, :release)
    assert :ok = Task.await(task1, 500)
  end

  test "owner death reclaims capacity", %{server: server} do
    opts = [route_concurrency_server: server]
    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, _lease} = RouteConcurrency.acquire(:provider_a, :arbor, opts)
        send(parent, :acquired)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :acquired, 500
    ref = Process.monitor(holder)
    send(holder, :die)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}, 500

    # Poll briefly for DOWN reclaim on the GenServer.
    assert wait_until(fn ->
             case RouteConcurrency.snapshot(opts) do
               {:ok, snap} -> snap[{"provider_a", "arbor"}].concurrency_in_use == 0
               _ -> false
             end
           end)

    assert {:ok, _} = RouteConcurrency.acquire(:provider_a, :arbor, opts)
  end

  test "forged lease release is idempotent no-op", %{pid: pid} do
    assert :ok = RouteConcurrency.release({:route_concurrency_lease, pid, make_ref()})
    assert :ok = RouteConcurrency.release(:not_a_lease)
    # Atom server ref is invalid lease shape (must be PID).
    assert :ok = RouteConcurrency.release({:route_concurrency_lease, :some_name, make_ref()})
  end

  test "unavailable authority when server is down" do
    missing = :"missing_rc_#{System.unique_integer([:positive])}"
    assert {:error, :unavailable} = RouteConcurrency.acquire(:provider_a, :arbor, route_concurrency_server: missing)
    assert {:error, :unavailable} = RouteConcurrency.snapshot(route_concurrency_server: missing)
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    assert :ok = RouteConcurrency.release({:route_concurrency_lease, dead, make_ref()})
  end

  test "malformed configuration refuses to start" do
    name = :"bad_rc_#{System.unique_integer([:positive])}"

    assert {:error, :malformed_config} =
             start_supervised({RouteConcurrency, name: name, limits: %{"" => %{arbor: 1}}})
  end

  test "snapshot is exact and bounded", %{server: server} do
    opts = [route_concurrency_server: server]
    assert {:ok, snap} = RouteConcurrency.snapshot(opts)
    assert map_size(snap) == 3
    assert snap[{"provider_a", "arbor"}].concurrency_limit == 1
    assert snap[{"provider_b", "acp"}].concurrency_limit == 0
  end

  defp wait_until(fun, attempts \\ 20) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
