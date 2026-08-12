defmodule Arbor.Memory.ThinkingOwnerAdmissionTest do
  @moduledoc """
  Thinking owner-root acknowledgement, stream, reload, and live-upgrade tests
  (VP-05D2C3I1B1C).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.OwnerRoots
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Thinking
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1C"

  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_thinking

  setup do
    ensure_durable_store!()
    ensure_thinking!()
    ensure_provenance!()
    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
    :ok
  end

  test "coalesced deferred roots block drain until successful convergence" do
    agent_id = unique_agent("coal")
    taint = taint(:trusted, :internal, "thinking_owner_coal")

    drain_task =
      with_provenance_unregistered(fn ->
        assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "first miss", taint)
        assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "second miss", taint)
        assert OwnerRoots.held_count(owner_roots(), agent_id) == 2
        assert Map.get(:sys.get_state(Thinking).pending_projection, agent_id) == 1

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 5_000) end)

        assert eventually(fn ->
                 match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id)) and
                   OwnerRoots.held_count(owner_roots(), agent_id) == 2
               end)

        task
      end)

    assert eventually(fn ->
             state = :sys.get_state(Thinking)

             not Map.has_key?(state.pending_projection, agent_id) and
               OwnerRoots.held_count(owner_roots(), agent_id) == 0
           end)

    assert {:ok, _fence} = Task.await(drain_task, 5_000)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "bounded exhaustion settles coalesced roots" do
    agent_id = unique_agent("exh")
    taint = taint(:trusted, :internal, "thinking_owner_exh")

    with_provenance_unregistered(fn ->
      assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "exhaust first", taint)
      assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "exhaust second", taint)

      assert eventually(fn ->
               state = :sys.get_state(Thinking)

               not Map.has_key?(state.pending_projection, agent_id) and
                 OwnerRoots.held_count(owner_roots(), agent_id) == 0
             end)
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "immediate success, empty completion, validation, backend, and caught failures leave no fresh root" do
    agent_id = unique_agent("imm")
    assert {:ok, _} = Thinking.record_thinking(agent_id, "immediate success")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)

    assert :ok = Thinking.process_stream_chunk(agent_id, "", complete: true)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :invalid_request} = Thinking.record_thinking(agent_id, "x", significant: "no")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    max_bytes = Arbor.Memory.ThinkingCodec.max_text_bytes()

    assert {:error, :invalid_payload} =
             Thinking.process_stream_chunk(agent_id, String.duplicate("o", max_bytes + 1))

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    pid = Process.whereis(Thinking)
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state -> Map.delete(state, :buffer_size) end)

    try do
      assert {:error, :store_unavailable} = Thinking.record_thinking(agent_id, "caught after admit")
      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    after
      :sys.replace_state(pid, fn state ->
        Map.put(state, :buffer_size, Map.get(original, :buffer_size, 50))
      end)
    end

    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    try do
      assert {:error, reason} = Thinking.record_thinking(agent_id, "backend down")
      assert reason in [:store_unavailable, :outcome_unknown]
      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    after
      ensure_durable_store!()
    end

    task_a = Task.async(fn -> Thinking.record_thinking(agent_id, "cas a") end)
    task_b = Task.async(fn -> Thinking.record_thinking(agent_id, "cas b") end)
    _ = Task.await(task_a, 5_000)
    _ = Task.await(task_b, 5_000)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "incomplete chunks acknowledge immediately and completion admits separately" do
    agent_id = unique_agent("chunk")
    assert :ok = Thinking.process_stream_chunk(agent_id, "part one")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert Map.has_key?(:sys.get_state(Thinking).streams, agent_id)

    assert :ok = Thinking.process_stream_chunk(agent_id, " part two")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    assert {:ok, entry} = Thinking.process_stream_chunk(agent_id, "", complete: true)
    assert entry.text == "part one part two"
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    refute Map.has_key?(:sys.get_state(Thinking).streams, agent_id)
    await_idle_roots!(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "B0 embedding execution owns only its separate root" do
    agent_id = unique_agent("embed")
    assert :ok = Thinking.process_stream_chunk(agent_id, "no embed yet")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:ok, _} = Thinking.record_thinking(agent_id, "embed after record")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    case MutationAdmission.status(agent_id) do
      {:ok, %{active_roots: n}} when n >= 1 ->
        assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

      {:ok, %{active_roots: 0}} ->
        :ok
    end

    await_idle_roots!(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "failed projection retains a root before the retry timer is observable" do
    agent_id = unique_agent("timer")
    taint = taint(:trusted, :internal, "thinking_owner_timer")
    assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "timer seed", taint)
    await_idle_roots!(agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "timer arm", taint)
      state = :sys.get_state(Thinking)
      assert Map.has_key?(state.pending_projection, agent_id)
      assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
      assert match?({:ok, %{active_roots: n}} when n >= 1, MutationAdmission.status(agent_id))
    end)

    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "content-only cleanup disarms retries, settles roots, and retains sidecars" do
    agent_id = unique_agent("clean")
    taint = taint(:trusted, :internal, "thinking_owner_clean")
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "cleanup target", taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:thinking_entry, agent_id)
    assert entry.id in ids_before

    with_provenance_unregistered(fn ->
      assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "arm cleanup", taint)
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) > 0

    assert :ok = Thinking.delete_agent_content(agent_id)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    state = :sys.get_state(Thinking)
    refute Map.has_key?(state.pending_projection, agent_id)
    refute Map.has_key?(state.streams, agent_id)
    refute MapSet.member?(state.owned_agents, agent_id)
    await_idle_roots!(agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, agent_id)

    send(Process.whereis(Thinking), {:converge_projection, agent_id})
    _ = :sys.get_state(Thinking)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, agent_id)
    assert {:ok, true} = Thinking.agent_content_absent?(agent_id)
  end

  test "restart during drain skips the drained agent and hydrates a sibling" do
    agent_a = unique_agent("rst_a")
    agent_b = unique_agent("rst_b")
    taint = taint(:trusted, :internal, "thinking_owner_rst")

    assert {:ok, _} = Thinking.record_thinking_tainted(agent_a, "drained agent", taint)
    assert {:ok, entry_b} = Thinking.record_thinking_tainted(agent_b, "open sibling", taint)
    await_idle_roots!(agent_a)
    await_idle_roots!(agent_b)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Thinking)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Thinking)
    assert is_pid(Process.whereis(Thinking))

    assert [] = :ets.lookup(@ets_table, agent_a)
    assert [{^agent_b, entries}] = :ets.lookup(@ets_table, agent_b)
    assert Enum.any?(entries, &(&1.id == entry_b.id))
    assert durable_present?(agent_a)

    assert :ok = Thinking.delete_agent_content(agent_a)
    assert :ok = Thinking.delete_agent_content(agent_b)
  end

  test "public reload skips a draining agent, hydrates a sibling, and admits absence eviction" do
    agent_a = unique_agent("rel_a")
    agent_b = unique_agent("rel_b")
    agent_c = unique_agent("rel_c")
    taint = taint(:trusted, :internal, "thinking_owner_rel")

    assert {:ok, _} = Thinking.record_thinking_tainted(agent_a, "drained reload", taint)
    assert {:ok, entry_b} = Thinking.record_thinking_tainted(agent_b, "open reload", taint)
    assert {:ok, entry_c} = Thinking.record_thinking_tainted(agent_c, "absence eviction", taint)
    await_idle_roots!(agent_a)
    await_idle_roots!(agent_b)
    await_idle_roots!(agent_c)

    assert :ok = MemoryStore.delete_tainted_authoritative("thinking", agent_c)
    assert [{^agent_c, _}] = :ets.lookup(@ets_table, agent_c)

    assert {:ok, _fence} = MutationAdmission.drain(agent_a)
    assert true == :ets.delete(@ets_table, agent_a)

    assert {:error, :store_unavailable} = Thinking.reload_from_durable()
    assert [] = :ets.lookup(@ets_table, agent_a)
    assert [{^agent_b, entries}] = :ets.lookup(@ets_table, agent_b)
    assert Enum.any?(entries, &(&1.id == entry_b.id))
    assert [] = :ets.lookup(@ets_table, agent_c)
    refute MapSet.member?(:sys.get_state(Thinking).owned_agents, agent_c)
    assert durable_present?(agent_a)
    assert durable_present?(agent_b)
    refute durable_present?(agent_c)

    _ = entry_c
    assert :ok = Thinking.delete_agent_content(agent_a)
    assert :ok = Thinking.delete_agent_content(agent_b)
    assert :ok = Thinking.delete_agent_content(agent_c)
  end

  test "legacy state with an open gate acquires a fresh deferred root before repair" do
    agent_id = unique_agent("upgrade")
    taint = taint(:trusted, :internal, "thinking_owner_upgrade")
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "legacy open repair", taint)

    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:thinking_entry, agent_id, entry.id)

    pid = Process.whereis(Thinking)

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
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "legacy retry exception settles the post-acquisition root" do
    agent_id = unique_agent("catch")
    taint = taint(:trusted, :internal, "thinking_owner_catch")
    assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "catch target", taint)
    await_idle_roots!(agent_id)
    assert {:ok, %{gate: :open, active_roots: 0}} = MutationAdmission.status(agent_id)

    pid = Process.whereis(Thinking)
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_projection, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.delete(:buffer_size)
      |> Map.put(:pending_projection, Map.put(pending, agent_id, 1))
    end)

    send(pid, {:converge_projection, agent_id})
    _ = :sys.get_state(pid)

    assert Process.whereis(Thinking) == pid
    assert Process.alive?(pid)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :buffer_size, Map.get(original, :buffer_size, 50))
    end)

    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "roots and drain on one agent do not block another" do
    agent_a = unique_agent("iso_a")
    agent_b = unique_agent("iso_b")
    taint = taint(:trusted, :internal, "thinking_owner_iso")

    assert {:ok, _} = Thinking.record_thinking_tainted(agent_a, "isolated a", taint)
    await_idle_roots!(agent_a)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert {:ok, _} = Thinking.record_thinking_tainted(agent_b, "isolated b", taint)
    assert [%{text: "isolated b"}] = Thinking.recent_thinking(agent_b)

    assert {:error, :store_unavailable} = Thinking.record_thinking(agent_a, "blocked")
    assert :ok = Thinking.delete_agent_content(agent_a)
    assert :ok = Thinking.delete_agent_content(agent_b)
  end

  test "format_status exposes only per-agent held counts and redacts stream text" do
    agent_id = unique_agent("fmt")
    taint = taint(:trusted, :internal, "thinking_owner_fmt")
    secret = "stream secret text #{agent_id}"

    with_provenance_unregistered(fn ->
      assert :ok = Thinking.process_stream_chunk_tainted(agent_id, secret, taint)
      assert {:ok, _} = Thinking.record_thinking_tainted(agent_id, "fmt", taint)
      dump = inspect(:sys.get_status(Thinking), limit: :infinity)
      refute dump =~ "Arbor.Memory.MutationAdmission.Lease"
      refute dump =~ "%Arbor.Memory.MutationAdmission.OwnerRoots"
      refute dump =~ secret
    end)

    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "code_change normalizes legacy state missing new fields" do
    pid = Process.whereis(Thinking)
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.delete(:owner_roots)
      |> Map.delete(:pending_projection)
    end)

    assert {:ok, normalized} = Thinking.code_change(1, :sys.get_state(pid), [])
    assert %OwnerRoots{} = normalized.owner_roots
    assert normalized.pending_projection == %{}

    :sys.replace_state(pid, fn _ -> original end)
  end

  defp owner_roots do
    case :sys.get_state(Thinking) do
      %{owner_roots: %OwnerRoots{} = roots} -> roots
      _ -> OwnerRoots.new()
    end
  end

  defp unique_agent(label), do: "thinking_own_#{label}_#{System.unique_integer([:positive])}"

  defp durable_present?(agent_id) do
    match?(
      {:ok, _value, _status, _record, _location},
      MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id)
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

  defp ensure_thinking! do
    case Process.whereis(Thinking) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Thinking) do
          {:ok, pid} when is_pid(pid) -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
          other -> flunk("failed to restart Thinking: #{inspect(other)}")
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
