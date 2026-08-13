defmodule Arbor.Memory.AsyncWriterReservationTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Memory.AsyncWriter.Reservation
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.AsyncWriter.Worker
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Test.AsyncWriterHangBackend, as: Hang
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B2A"
  @store_name :arbor_memory_durable

  defmodule BlockingEmbedSeam do
    @moduledoc false

    alias Arbor.Memory.MemoryStoreIdentity

    def fetch(agent_id, namespace, key, _opts) do
      tester = Application.fetch_env!(:arbor_memory, :async_writer_reservation_embed_tester)
      send(tester, {:embed_blocked, self(), agent_id, namespace, key})

      receive do
        :release_embed -> {:error, :not_found}
      after
        10_000 -> {:error, :unavailable}
      end
    end

    def encode_operation(closed), do: {:ok, {:embed_operation, closed}, %{}}

    def execute(agent_id, {:embed_operation, closed}, _opts) do
      tester = Application.fetch_env!(:arbor_memory, :async_writer_reservation_embed_tester)
      namespace = Map.get(closed, :source_namespace) || Map.fetch!(closed, :namespace)
      key = Map.get(closed, :source_key) || Map.fetch!(closed, :key)
      send(tester, {:embed_executed, agent_id, namespace, key})

      {:ok,
       %{
         record: %{
           agent_id: agent_id,
           source_namespace: namespace,
           source_key: key,
           id: MemoryStoreIdentity.row_id(agent_id, namespace, key)
         }
       }}
    end

    def reconcile(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  setup do
    hang_name = :async_writer_reservation_hang_backend
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

  test "reserved worker owns one root and performs no effect until activate", %{
    hang_name: hang_name
  } do
    agent_id = unique_agent("reserved")
    key = "reserved-#{System.unique_integer([:positive])}"

    assert {:ok, %Reservation{} = reservation} =
             MemoryStore.reserve_persist_async("async_writer", key, %{"secret" => "payload"},
               agent_id: agent_id
             )

    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)
    assert length(writer_children()) == 1
    assert Hang.cas_count(hang_name) == 0
    refute_receive {:async_writer_hang, _, _}, 100

    assert {:error, :not_found} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")

    tester = self()

    _drain_pid =
      spawn(fn ->
        send(tester, {:drain_done, MutationAdmission.drain(agent_id, timeout_ms: 5_000)})
      end)

    refute_receive {:drain_done, _}, 200
    assert {:ok, %{gate: :draining, active_roots: 1}} = MutationAdmission.status(agent_id)

    assert :ok = MemoryStore.activate_async(reservation)
    assert {:ok, _ref, _blocked} = Hang.await_hang()
    assert Process.alive?(Reservation.worker(reservation))
    refute_receive {:drain_done, _}, 100

    Hang.release(hang_name)
    assert_receive {:drain_done, {:ok, fence}}, 3_000
    assert fence.agent_id == agent_id

    wait_until(fn -> writer_children() == [] end)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, %Record{data: %{"secret" => "payload"}}} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")
  end

  test "cancel, expiry, and owner death release a reserved root with no effect", %{
    hang_name: hang_name
  } do
    cancel_id = unique_agent("cancel")
    expire_id = unique_agent("expire")
    death_id = unique_agent("death")

    assert {:ok, cancel_res} =
             MemoryStore.reserve_persist_async("async_writer", "cancel", %{"v" => 1},
               agent_id: cancel_id
             )

    assert :ok = MemoryStore.cancel_async(cancel_res)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(cancel_id)) end)
    assert {:ok, _fence} = MutationAdmission.drain(cancel_id)
    assert Hang.cas_count(hang_name) == 0

    assert {:ok, expire_res} =
             MemoryStore.reserve_persist_async("async_writer", "expire", %{"v" => 1},
               agent_id: expire_id
             )

    expire_worker = Reservation.worker(expire_res)
    state = :sys.get_state(expire_worker)
    send(expire_worker, {:reservation_deadline, state.msg_ref})
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(expire_id)) end)
    assert {:ok, _fence} = MutationAdmission.drain(expire_id)

    kill_id = unique_agent("kill")

    assert {:ok, kill_res} =
             MemoryStore.reserve_persist_async("async_writer", "kill", %{"v" => 1},
               agent_id: kill_id
             )

    mon = Process.monitor(Reservation.worker(kill_res))
    Process.exit(Reservation.worker(kill_res), :kill)
    assert_receive {:DOWN, ^mon, :process, _pid, :killed}, 2_000
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(kill_id)) end)
    assert {:ok, _fence} = MutationAdmission.drain(kill_id)

    tester = self()

    owner =
      spawn(fn ->
        send(
          tester,
          {:reserved,
           MemoryStore.reserve_persist_async("async_writer", "death", %{"v" => 1},
             agent_id: death_id
           )}
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:reserved, {:ok, _death_res}}, 2_000
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(death_id)
    Process.exit(owner, :kill)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(death_id)) end)
    assert {:ok, _fence} = MutationAdmission.drain(death_id)
    assert Hang.cas_count(hang_name) == 0
    assert writer_children() == []
  end

  test "queued late activate cannot commit after its deadline", %{hang_name: hang_name} do
    agent_id = unique_agent("late")
    key = "late-#{System.unique_integer([:positive])}"

    assert {:ok, reservation} =
             MemoryStore.reserve_persist_async("async_writer", key, %{"late" => true},
               agent_id: agent_id
             )

    worker = Reservation.worker(reservation)
    :sys.suspend(worker)
    past = System.monotonic_time(:millisecond) - 1
    ref = make_ref()

    send(
      worker,
      {:"$gen_call", {self(), ref},
       {:activate, Reservation.token(reservation), Reservation.owner(reservation), past}}
    )

    wait_until(fn ->
      {:message_queue_len, len} = Process.info(worker, :message_queue_len)
      len >= 1
    end)

    :sys.resume(worker)
    assert_receive {^ref, {:error, {:memory_store, :async_writer, :expired}}}, 2_000
    assert Hang.cas_count(hang_name) == 0

    assert {:error, :not_found} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")

    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    refute Process.alive?(worker)

    assert {:error, {:memory_store, :async_writer, retry_reason}} =
             MemoryStore.activate_async(reservation)

    assert retry_reason in [:expired, :invalid_reservation, :unavailable]

    assert {:error, {:memory_store, :async_writer, cancel_reason}} =
             MemoryStore.cancel_async(reservation)

    assert cancel_reason in [:invalid_reservation, :unavailable]
    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
  end

  test "duplicate, foreign, and malformed activate/cancel are effect-free", %{
    hang_name: hang_name
  } do
    agent_id = unique_agent("dup")
    key = "dup-#{System.unique_integer([:positive])}"
    payload = %{"secret-payload" => "do-not-leak"}

    assert {:ok, reservation} =
             MemoryStore.reserve_persist_async("async_writer", key, payload, agent_id: agent_id)

    token = Reservation.token(reservation)
    token_text = inspect(token)
    inspected = inspect(reservation)
    refute inspected =~ "secret-payload"
    refute inspected =~ token_text
    refute inspected =~ inspect(Reservation.owner(reservation))

    worker = Reservation.worker(reservation)

    assert %{state: redacted} =
             Worker.format_status(%{
               state: %{
                 phase: :reserved,
                 token: token,
                 lease: :secret_lease,
                 operation: {:persist, %{data: payload}}
               }
             })

    assert redacted.phase == :reserved
    refute Map.has_key?(redacted, :token)
    refute Map.has_key?(redacted, :lease)
    assert %{} = Worker.format_status(%{})
    assert %{state: :not_a_map} = Worker.format_status(%{state: :not_a_map})

    status_text = inspect(:sys.get_status(worker))
    refute status_text =~ "secret-payload"
    refute status_text =~ token_text

    child_text = inspect(writer_children())
    refute child_text =~ "secret-payload"

    assert :ok = MemoryStore.activate_async(reservation)
    assert {:ok, _ref, _blocked} = Hang.await_hang()

    assert {:error, {:memory_store, :async_writer, reason}} =
             MemoryStore.activate_async(reservation)

    assert reason in [:invalid_reservation, :unavailable]

    foreign = spawn(fn -> :ok end)

    assert {:error, {:memory_store, :async_writer, :invalid_reservation}} =
             MemoryStore.activate_async(%{reservation | owner: foreign})

    assert {:error, {:memory_store, :async_writer, :invalid_reservation}} =
             MemoryStore.cancel_async(%{reservation | owner: foreign})

    assert {:error, {:memory_store, :async_writer, :invalid_reservation}} =
             MemoryStore.activate_async(:not_a_reservation)

    assert {:error, {:memory_store, :async_writer, :invalid_reservation}} =
             MemoryStore.cancel_async(nil)

    assert Hang.cas_count(hang_name) == 1
    Hang.release(hang_name)
    wait_until(fn -> writer_children() == [] end)
  end

  test "immediate persist_async keeps caller independence, capacity, and worker-death cleanup",
       %{hang_name: hang_name} do
    caller_id = unique_agent("caller")
    key = "caller-#{System.unique_integer([:positive])}"
    tester = self()

    caller =
      spawn(fn ->
        send(
          tester,
          {:caller_started,
           MemoryStore.persist_async("async_writer", key, %{"once" => true}, agent_id: caller_id)}
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:caller_started, :ok}, 2_000
    assert {:ok, _ref, _blocked} = Hang.await_hang()
    Process.exit(caller, :kill)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(caller_id)
    Hang.release(hang_name)

    wait_until(fn ->
      match?(
        {:ok, %Record{data: %{"once" => true}}},
        Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")
      )
    end)

    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(caller_id)) end)

    cas_before_get_hang = Hang.cas_count(hang_name)
    Hang.arm_get_hang(hang_name)
    death_id = unique_agent("worker_death")
    death_key = "death-#{System.unique_integer([:positive])}"

    assert :ok =
             MemoryStore.persist_async("async_writer", death_key, %{"killed" => true},
               agent_id: death_id
             )

    assert {:ok, _ref, blocked_pid} = Hang.await_hang()
    assert Hang.cas_count(hang_name) == cas_before_get_hang
    [{_id, worker, _type, _mods}] = writer_children()
    refute worker == blocked_pid
    worker_mon = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 2_000
    Hang.release(hang_name)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(death_id)) end)
    assert writer_children() == []

    assert {:error, :not_found} =
             Persistence.buffered_store_authoritative_get(
               @store_name,
               "async_writer:#{death_key}"
             )

    original = Application.get_env(:arbor_memory, :async_writer_max_children)
    Application.put_env(:arbor_memory, :async_writer_max_children, 1)
    restart_writer_supervisor!()

    on_exit(fn ->
      restore_max_children(original)
      restart_writer_supervisor!()
    end)

    Hang.arm_hang(hang_name)
    cap_a = unique_agent("cap_a")
    cap_b = unique_agent("cap_b")

    assert :ok =
             MemoryStore.persist_async("async_writer", "cap-a", %{"slot" => 1}, agent_id: cap_a)

    assert {:ok, _ref, _blocked} = Hang.await_hang()

    assert {:error, {:memory_store, :async_writer, :capacity_exceeded}} =
             MemoryStore.persist_async("async_writer", "cap-b", %{"slot" => 2}, agent_id: cap_b)

    assert {:error, {:memory_store, :async_writer, :capacity_exceeded}} =
             MemoryStore.embed_async("async_writer", "cap-b", "effectful embed",
               agent_id: cap_b,
               type: :thought
             )

    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(cap_b)
    Hang.release(hang_name)
    wait_until(fn -> writer_children() == [] end)
  end

  test "immediate embed_async survives caller death after activation" do
    original_seam = Application.get_env(:arbor_memory, :strict_vector_seam)
    original_tester = Application.get_env(:arbor_memory, :async_writer_reservation_embed_tester)
    original_fallback = Application.get_env(:arbor_ai, :embedding_test_fallback)

    Application.put_env(:arbor_memory, :strict_vector_seam, BlockingEmbedSeam)
    Application.put_env(:arbor_memory, :async_writer_reservation_embed_tester, self())
    Application.put_env(:arbor_ai, :embedding_test_fallback, true)

    on_exit(fn ->
      restore_env(:arbor_memory, :strict_vector_seam, original_seam)
      restore_env(:arbor_memory, :async_writer_reservation_embed_tester, original_tester)
      restore_env(:arbor_ai, :embedding_test_fallback, original_fallback)
    end)

    agent_id = unique_agent("embed_caller")
    key = "embed-caller-#{System.unique_integer([:positive])}"
    tester = self()

    caller =
      spawn(fn ->
        result =
          MemoryStore.embed_async("async_writer", key, "caller-independent embed",
            agent_id: agent_id,
            type: :thought
          )

        send(tester, {:embed_started, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:embed_started, ^caller, :ok}, 5_000

    assert_receive {:embed_blocked, worker, ^agent_id, "async_writer", ^key}, 5_000
    assert Process.alive?(worker)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    caller_mon = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_mon, :process, ^caller, :killed}, 2_000
    assert Process.alive?(worker)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    send(worker, :release_embed)
    assert_receive {:embed_executed, ^agent_id, "async_writer", ^key}, 5_000
    wait_until(fn -> writer_children() == [] end)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
  end

  test "invalid persist and embed input create no worker or root" do
    before = writer_children()
    agent_id = unique_agent("invalid")

    assert {:error, {:memory_store, :invalid_request, :invalid_agent_id}} =
             MemoryStore.reserve_persist_async("async_writer", "k", %{"v" => 1})

    assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
             MemoryStore.reserve_persist_async("async_writer", "k", %{}, [:taint])

    assert :ok = MemoryStore.reserve_embed_async("async_writer", "k", "")
    assert writer_children() == before
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "parent denial after reserve cancels the child with no Preferences effect", %{
    hang_name: hang_name
  } do
    agent_id = unique_agent("parent_deny")

    assert {:ok, reservation} =
             MemoryStore.reserve_persist_async(
               "preferences",
               agent_id,
               %{"agent_id" => agent_id},
               agent_id: agent_id
             )

    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)
    tester = self()

    spawn(fn ->
      send(tester, {:drain_done, MutationAdmission.drain(agent_id, timeout_ms: 5_000)})
    end)

    wait_until(fn ->
      match?(
        {:ok, %{gate: :draining, active_roots: n}} when n >= 1,
        MutationAdmission.status(agent_id)
      )
    end)

    assert {:error, :draining} = MutationAdmission.acquire(agent_id)
    assert :ok = MemoryStore.cancel_async(reservation)
    assert_receive {:drain_done, {:ok, _fence}}, 3_000
    assert [] = :ets.lookup(:arbor_preferences, agent_id)
    assert Hang.cas_count(hang_name) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp unique_agent(label), do: "aw_res_#{label}_#{System.unique_integer([:positive])}"

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
        receive do
        after
          10 -> wait_loop(fun, deadline)
        end
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
