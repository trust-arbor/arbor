defmodule Arbor.Memory.AsyncWriterLifecycleTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Test.AsyncWriterHangBackend, as: Hang
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B0"
  @store_name :arbor_memory_durable

  setup do
    hang_name = :"aw_hang_#{System.unique_integer([:positive])}"
    {:ok, _} = Hang.start_link(agent_name: hang_name)
    Hang.arm_hang(hang_name)

    stop_store()

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: Hang,
       backend_opts: [agent_name: hang_name],
       write_mode: :sync,
       ack_mode: :backend}
    )

    on_exit(fn ->
      Hang.release(hang_name)
      Hang.stop(hang_name)
    end)

    {:ok, hang_name: hang_name}
  end

  test "drain cannot fence until persist is acknowledged and the worker exits", %{
    hang_name: hang_name
  } do
    agent_id = "aw_block_#{System.unique_integer([:positive])}"
    key = "blocked-#{System.unique_integer([:positive])}"

    assert :ok =
             MemoryStore.persist_async("async_writer", key, %{"blocked" => true},
               agent_id: agent_id
             )

    assert {:ok, _ref, blocked_pid} = Hang.await_hang()
    assert is_pid(blocked_pid)
    assert Process.alive?(blocked_pid)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)
    assert length(writer_children()) == 1

    tester = self()

    drain_pid =
      spawn(fn ->
        send(tester, {:drain_done, MutationAdmission.drain(agent_id, timeout_ms: 5_000)})
      end)

    refute_receive {:drain_done, _}, 200
    assert Process.alive?(drain_pid)

    Hang.release(hang_name)

    assert_receive {:drain_done, {:ok, fence}}, 3_000
    assert fence.agent_id == agent_id

    wait_until(fn -> writer_children() == [] end)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, %Record{data: %{"blocked" => true}}} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")
  end

  test "caller death does not cancel admitted persist", %{hang_name: hang_name} do
    agent_id = "aw_caller_#{System.unique_integer([:positive])}"
    key = "caller-#{System.unique_integer([:positive])}"
    tester = self()

    caller =
      spawn(fn ->
        send(
          tester,
          {:caller_started,
           MemoryStore.persist_async("async_writer", key, %{"once" => true}, agent_id: agent_id)}
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:caller_started, :ok}, 2_000
    assert {:ok, _ref, _blocked} = Hang.await_hang()
    assert Process.alive?(caller)
    Process.exit(caller, :kill)
    refute Process.alive?(caller)

    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)
    Hang.release(hang_name)

    wait_until(fn ->
      match?(
        {:ok, %Record{data: %{"once" => true}}},
        Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")
      )
    end)

    wait_until(fn -> writer_children() == [] end)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, %Record{data: %{"once" => true}}} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")

    assert Hang.cas_count(hang_name) == 1
  end

  test "worker death converges through the guardian without a leaked root or effect", %{
    hang_name: hang_name
  } do
    agent_id = "aw_worker_#{System.unique_integer([:positive])}"
    key = "worker-#{System.unique_integer([:positive])}"

    Hang.arm_get_hang(hang_name)

    assert :ok =
             MemoryStore.persist_async("async_writer", key, %{"killed" => true},
               agent_id: agent_id
             )

    assert {:ok, _ref, blocked_pid} = Hang.await_hang()
    assert is_pid(blocked_pid)
    assert Process.alive?(blocked_pid)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)
    assert length(writer_children()) == 1
    assert Hang.cas_count(hang_name) == 0

    [{_id, worker, _type, _mods}] = writer_children()
    refute worker == blocked_pid
    mon = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^mon, :process, ^worker, :killed}, 2_000

    Hang.release(hang_name)

    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    assert writer_children() == []
    assert Hang.cas_count(hang_name) == 0

    assert {:error, :not_found} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")

    assert {:ok, fence} = MutationAdmission.drain(agent_id)
    assert fence.agent_id == agent_id
  end

  test "capacity exhaustion rejects before a second effect", %{hang_name: hang_name} do
    original = Application.get_env(:arbor_memory, :async_writer_max_children)
    Application.put_env(:arbor_memory, :async_writer_max_children, 1)
    restart_writer_supervisor!()

    on_exit(fn ->
      restore_max_children(original)
      restart_writer_supervisor!()
    end)

    agent_a = "aw_cap_a_#{System.unique_integer([:positive])}"
    agent_b = "aw_cap_b_#{System.unique_integer([:positive])}"
    key_a = "cap-a-#{System.unique_integer([:positive])}"
    key_b = "cap-b-#{System.unique_integer([:positive])}"

    assert :ok =
             MemoryStore.persist_async("async_writer", key_a, %{"slot" => 1}, agent_id: agent_a)

    assert {:ok, _ref, _blocked} = Hang.await_hang()
    assert length(writer_children()) == 1

    assert {:error, {:memory_store, :async_writer, :capacity_exceeded}} =
             MemoryStore.persist_async("async_writer", key_b, %{"slot" => 2}, agent_id: agent_b)

    assert length(writer_children()) == 1
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_b)

    Hang.release(hang_name)
    wait_until(fn -> writer_children() == [] end)

    assert {:ok, %Record{data: %{"slot" => 1}}} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key_a}")

    assert {:error, :not_found} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key_b}")
  end

  defp writer_children do
    case Process.whereis(WriterSupervisor.name()) do
      nil -> []
      pid -> DynamicSupervisor.which_children(pid)
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(10)
        wait_loop(fun, deadline)
      end
    end
  end

  defp stop_store do
    case Process.whereis(@store_name) do
      nil ->
        :ok

      _pid ->
        _ = stop_supervised(BufferedStore)
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp restart_writer_supervisor! do
    id = WriterSupervisor.name()
    _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, id)
    _ = Supervisor.delete_child(Arbor.Memory.Supervisor, id)

    case Supervisor.start_child(Arbor.Memory.Supervisor, {WriterSupervisor, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> flunk("failed to restart writer supervisor: #{inspect(reason)}")
    end
  end

  defp restore_max_children(nil),
    do: Application.delete_env(:arbor_memory, :async_writer_max_children)

  defp restore_max_children(value),
    do: Application.put_env(:arbor_memory, :async_writer_max_children, value)
end
