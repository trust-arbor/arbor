defmodule Arbor.Memory.IntentStoreOwnerAdmissionTest do
  @moduledoc """
  IntentStore owner-root acknowledgement and live-upgrade tests (VP-05D2C3I1B1B).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.IntentStore
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.OwnerRoots
  alias Arbor.Memory.Provenance
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Signals, as: SignalBus

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @moduletag packet: "VP-05D2C3I1B1B"

  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_intents

  setup do
    ensure_durable_store!()
    ensure_intent_store!()
    ensure_provenance!()
    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
    :ok
  end

  test "coalesced deferred roots block drain until successful convergence" do
    agent_id = unique_agent("coal")
    taint = taint(:trusted, :internal, "intent_owner_coal")
    first = Intent.think("first miss")
    second = Intent.think("second miss")

    drain_task =
      with_provenance_unregistered(fn ->
        assert {:ok, ^first} = IntentStore.record_intent_tainted(agent_id, first, taint)
        assert {:ok, ^second} = IntentStore.record_intent_tainted(agent_id, second, taint)
        assert OwnerRoots.held_count(owner_roots(), agent_id) == 2

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 5_000) end)

        assert eventually(fn ->
                 match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id)) and
                   OwnerRoots.held_count(owner_roots(), agent_id) == 2
               end)

        task
      end)

    assert eventually(fn ->
             state = :sys.get_state(IntentStore)

             not Map.has_key?(state.pending_projection, agent_id) and
               OwnerRoots.held_count(owner_roots(), agent_id) == 0
           end)

    assert {:ok, _fence} = Task.await(drain_task, 5_000)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
  end

  test "bounded exhaustion settles coalesced roots" do
    agent_id = unique_agent("exh")
    taint = taint(:trusted, :internal, "intent_owner_exh")
    first = Intent.think("exhaust first")
    second = Intent.think("exhaust second")

    with_provenance_unregistered(fn ->
      assert {:ok, ^first} = IntentStore.record_intent_tainted(agent_id, first, taint)
      assert {:ok, ^second} = IntentStore.record_intent_tainted(agent_id, second, taint)

      assert eventually(fn ->
               state = :sys.get_state(IntentStore)

               not Map.has_key?(state.pending_projection, agent_id) and
                 OwnerRoots.held_count(owner_roots(), agent_id) == 0
             end)
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
  end

  test "immediate success, no-op, validation, not-found, and backend errors leave no fresh root" do
    agent_id = unique_agent("imm")
    intent = Intent.think("immediate success")
    assert {:ok, ^intent} = IntentStore.record_intent(agent_id, intent)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)

    assert 0 = IntentStore.unlock_stale_intents(agent_id, 60_000)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert 0 = IntentStore.prune_stale(agent_id, :timer.hours(24))
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    assert {:error, :invalid_request} = IntentStore.record_intent(agent_id, :not_an_intent)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:error, :invalid_request} = IntentStore.lock_intent("", "x")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    assert {:error, :not_found} = IntentStore.lock_intent(agent_id, "missing-intent")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)
    await_idle_roots!(agent_id)
    assert {:error, :not_lockable} = IntentStore.lock_intent(agent_id, intent.id)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    try do
      assert {:error, :store_unavailable} =
               IntentStore.record_intent(agent_id, Intent.think("backend down"))

      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    after
      ensure_durable_store!()
    end
  end

  test "caught paths cannot strand a root in a live owner" do
    agent_id = unique_agent("catch")
    taint = taint(:trusted, :internal, "intent_owner_catch")
    intent = Intent.think("catch target")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)

    with_provenance_unregistered(fn ->
      extra = Intent.think("arm catch")
      assert {:ok, ^extra} = IntentStore.record_intent_tainted(agent_id, extra, taint)
      assert OwnerRoots.held_count(owner_roots(), agent_id) > 0
    end)

    pid = Process.whereis(IntentStore)
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      Map.delete(state, :buffer_size)
    end)

    send(pid, {:converge_projection, agent_id})
    _ = :sys.get_state(pid)

    assert Process.whereis(IntentStore) == pid
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :buffer_size, Map.get(original, :buffer_size, 100))
    end)
  end

  test "content-only cleanup disarms retries, settles roots, and retains sidecars" do
    agent_id = unique_agent("clean")
    taint = taint(:trusted, :internal, "intent_owner_clean")
    intent = Intent.think("cleanup target")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:intent, agent_id)

    with_provenance_unregistered(fn ->
      extra = Intent.think("arm cleanup")
      assert {:ok, ^extra} = IntentStore.record_intent_tainted(agent_id, extra, taint)
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) > 0

    assert :ok = IntentStore.delete_agent_content(agent_id)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    state = :sys.get_state(IntentStore)
    refute Map.has_key?(state.pending_projection, agent_id)
    await_idle_roots!(agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, agent_id)

    send(Process.whereis(IntentStore), {:converge_projection, agent_id})
    _ = :sys.get_state(IntentStore)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, agent_id)
  end

  test "restart during drain skips the drained agent and hydrates a sibling" do
    agent_a = unique_agent("rst_a")
    agent_b = unique_agent("rst_b")
    taint = taint(:trusted, :internal, "intent_owner_rst")
    intent_a = Intent.think("drained agent")
    intent_b = Intent.think("open sibling")

    assert {:ok, ^intent_a} = IntentStore.record_intent_tainted(agent_a, intent_a, taint)
    assert {:ok, ^intent_b} = IntentStore.record_intent_tainted(agent_b, intent_b, taint)
    await_idle_roots!(agent_a)
    await_idle_roots!(agent_b)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, IntentStore)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, IntentStore)
    assert is_pid(Process.whereis(IntentStore))

    assert [] = :ets.lookup(@ets_table, agent_a)
    assert [{^agent_b, data}] = :ets.lookup(@ets_table, agent_b)
    assert Enum.any?(data.intents, &(&1.id == intent_b.id))
    assert durable_present?(agent_a)
  end

  test "legacy state with an open gate acquires a fresh deferred root before repair" do
    agent_id = unique_agent("upgrade")
    taint = taint(:trusted, :internal, "intent_owner_upgrade")
    intent = Intent.think("legacy open repair")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)

    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:intent, agent_id, intent.id)

    pid = Process.whereis(IntentStore)

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_projection, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.put(:pending_projection, Map.put(pending, agent_id, 1))
    end)

    send(pid, {:converge_projection, agent_id})
    _ = :sys.get_state(pid)

    assert eventually(fn ->
             match?([{^agent_id, _}], :ets.lookup(@ets_table, agent_id))
           end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
  end

  test "roots and drain on one agent do not block another" do
    agent_a = unique_agent("iso_a")
    agent_b = unique_agent("iso_b")
    taint = taint(:trusted, :internal, "intent_owner_iso")
    intent_a = Intent.think("isolated a")

    assert {:ok, ^intent_a} = IntentStore.record_intent_tainted(agent_a, intent_a, taint)
    await_idle_roots!(agent_a)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert {:ok, intent_b} = IntentStore.record_intent_tainted(agent_b, Intent.think("isolated b"), taint)
    assert [%{id: id}] = IntentStore.recent_intents(agent_b)
    assert id == intent_b.id
    assert {:error, :store_unavailable} = IntentStore.record_intent(agent_a, Intent.think("blocked"))
  end

  test "compatibility clear still purges intent Provenance" do
    agent_id = unique_agent("clear")
    taint = taint(:trusted, :internal, "intent_owner_clear")
    intent = Intent.think("clear me")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    assert {:ok, ids} = Provenance.list_item_ids(:intent, agent_id)
    assert intent.id in ids

    assert :ok = IntentStore.clear(agent_id)
    assert [] = IntentStore.recent_intents(agent_id)
    assert {:ok, after_ids} = Provenance.list_item_ids(:intent, agent_id)
    refute intent.id in after_ids
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
  end

  test "present durable restore failure stays pending even if ETS is evicted" do
    agent_id = unique_agent("pend")
    taint = taint(:trusted, :internal, "intent_owner_pend")
    intent = Intent.think("present durable")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    await_idle_roots!(agent_id)
    assert durable_present?(agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _items} = IntentStore.recent_intents_tainted(agent_id)
      state = :sys.get_state(IntentStore)
      assert Map.has_key?(state.pending_projection, agent_id)
      assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
    end)
  end

  test "failed projection retains a root before the retry timer is observable" do
    agent_id = unique_agent("timer")
    taint = taint(:trusted, :internal, "intent_owner_timer")
    intent = Intent.think("timer seed")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    await_idle_roots!(agent_id)

    with_provenance_unregistered(fn ->
      extra = Intent.think("timer arm")
      assert {:ok, ^extra} = IntentStore.record_intent_tainted(agent_id, extra, taint)
      state = :sys.get_state(IntentStore)
      assert Map.has_key?(state.pending_projection, agent_id)
      assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
      assert match?({:ok, %{active_roots: n}} when n >= 1, MutationAdmission.status(agent_id))
    end)
  end

  test "format_status exposes only per-agent held counts" do
    agent_id = unique_agent("fmt")
    taint = taint(:trusted, :internal, "intent_owner_fmt")

    with_provenance_unregistered(fn ->
      assert {:ok, _} = IntentStore.record_intent_tainted(agent_id, Intent.think("fmt"), taint)
      dump = inspect(:sys.get_status(IntentStore), limit: :infinity)
      refute dump =~ "Arbor.Memory.MutationAdmission.Lease"
      refute dump =~ "%Arbor.Memory.MutationAdmission.OwnerRoots"
    end)
  end

  test "embedding enqueue runs while the fresh root is held" do
    agent_id = unique_agent("embed")
    test_pid = self()
    pid = Process.whereis(IntentStore)

    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :embedding_fun, fn _ns, _key, _text, _opts ->
        {:ok, status} = MutationAdmission.status(agent_id)
        send(test_pid, {:embed_ack, status.active_roots})
        :ok
      end)
    end)

    try do
      assert {:ok, _} = IntentStore.record_intent(agent_id, Intent.think("embed under root"))
      assert_receive {:embed_ack, active_roots} when active_roots >= 1, 1_000
      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    after
      :sys.replace_state(pid, fn state ->
        Map.put(state, :embedding_fun, original.embedding_fun)
      end)
    end
  end

  test "embedding enqueue raise cannot bypass projection disposition" do
    agent_id = unique_agent("embed_err")
    taint = taint(:trusted, :internal, "intent_owner_embed_err")
    pid = Process.whereis(IntentStore)

    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :embedding_fun, fn _ns, _key, _text, _opts ->
        raise "embed"
      end)
    end)

    try do
      assert {:ok, _} = IntentStore.record_intent(agent_id, Intent.think("embed raise settle"))
      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

      with_provenance_unregistered(fn ->
        extra = Intent.think("embed raise defer")
        assert {:ok, ^extra} = IntentStore.record_intent_tainted(agent_id, extra, taint)
        state = :sys.get_state(IntentStore)
        assert Map.has_key?(state.pending_projection, agent_id)
        assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
      end)
    after
      :sys.replace_state(pid, fn state ->
        Map.put(state, :embedding_fun, original.embedding_fun)
      end)
    end
  end

  test "intent_formed is emitted only after root disposition" do
    agent_id = unique_agent("sig")
    test_pid = self()

    {:ok, sub} =
      SignalBus.subscribe(
        "agent.intent_formed",
        fn signal ->
          send(test_pid, {:intent_signal, signal, owner_roots(), MutationAdmission.status(agent_id)})
          :ok
        end,
        async: false
      )

    on_exit(fn -> SignalBus.unsubscribe(sub) end)

    assert {:ok, _} = IntentStore.record_intent(agent_id, Intent.think("signal after settle"))

    assert_receive {:intent_signal, _signal, roots, {:ok, status}}, 1_000
    assert OwnerRoots.held_count(roots, agent_id) == 0
    assert status.active_roots == 0
  end

  defp owner_roots do
    case :sys.get_state(IntentStore) do
      %{owner_roots: %OwnerRoots{} = roots} -> roots
      _ -> OwnerRoots.new()
    end
  end

  defp unique_agent(label), do: "intent_own_#{label}_#{System.unique_integer([:positive])}"

  defp durable_present?(agent_id) do
    match?(
      {:ok, _value, _status, _record, _location},
      MemoryStore.load_tainted_authoritative_with_status("intents", agent_id)
    )
  end

  defp await_idle_roots!(agent_id) do
    assert eventually(fn ->
             match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
           end)
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  defp ensure_intent_store! do
    case Process.whereis(IntentStore) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, IntentStore) do
          {:ok, pid} when is_pid(pid) -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
          other -> flunk("failed to restart IntentStore: #{inspect(other)}")
        end
    end
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp with_provenance_unregistered(fun) when is_function(fun, 0) do
    pid = Process.whereis(Provenance)
    assert is_pid(pid)
    assert Process.unregister(Provenance)

    try do
      fun.()
    after
      case Process.whereis(Provenance) do
        ^pid -> :ok
        nil -> Process.register(pid, Provenance)
        other -> flunk("Provenance name owned by #{inspect(other)}")
      end
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.() || flunk("condition not met")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp taint(level, sensitivity, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end
end
