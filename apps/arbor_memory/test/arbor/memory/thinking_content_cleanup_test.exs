defmodule Arbor.Memory.ThinkingContentCleanupTest do
  @moduledoc """
  Content-only Thinking cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{MemoryStore, Provenance, Thinking}
  alias Arbor.Persistence.BufferedStore

  require Supervisor

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_thinking

  @delete_errors [
    :invalid_request,
    :store_unavailable,
    :outcome_unknown,
    :conflict,
    :projection_failed
  ]

  @absence_errors [:invalid_request, :store_unavailable]

  setup do
    ensure_durable_store!()
    ensure_thinking!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = Thinking.clear(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      # Never call start_supervised!/2 from on_exit.
      ensure_provenance!()
      ensure_thinking!()

      # Sidecar cleanup is independent of durable availability.
      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      if MemoryStore.available?() do
        for agent <- [target, child, survivor] do
          _ = Thinking.clear(agent)
        end
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content removes durable/ETS/stream and retains provenance", %{
    target: target,
    child: child,
    survivor: survivor
  } do
    taint = taint(:trusted, :internal, "thinking_content_cleanup")

    assert {:ok, target_entry} =
             Thinking.record_thinking_tainted(target, "target thought", taint)

    assert {:ok, _child_entry} =
             Thinking.record_thinking_tainted(child, "child thought", taint)

    assert {:ok, _survivor_entry} =
             Thinking.record_thinking_tainted(survivor, "survivor thought", taint)

    assert {:ok, ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert target_entry.id in ids_before
    assert {:ok, false} = Thinking.agent_content_absent?(target)

    assert :ok = Thinking.process_stream_chunk_tainted(target, "partial stream", taint)
    assert {:ok, false} = Thinking.agent_content_absent?(target)

    assert :ok = Thinking.delete_agent_content(target)
    assert {:ok, true} = Thinking.agent_content_absent?(target)
    assert :ok = Thinking.delete_agent_content(target)
    assert {:ok, true} = Thinking.agent_content_absent?(target)

    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("thinking", target)

    state = :sys.get_state(Thinking)
    refute Map.has_key?(state.streams, target)

    assert length(Thinking.recent_thinking(child)) == 1
    assert length(Thinking.recent_thinking(survivor)) == 1
    assert {:ok, false} = Thinking.agent_content_absent?(child)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, target)

    hostile_payload = %{"id" => "hostile-thk", "text" => "x"}
    hostile = taint(:hostile, :restricted, "hostile_thinking")
    assert :ok = Provenance.put(:thinking_entry, target, "hostile-thk", hostile_payload, hostile)
    assert :ok = Thinking.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:thinking_entry, target, "hostile-thk", hostile_payload)
  end

  test "unfinished stream alone is not absent", %{target: target} do
    taint = taint(:trusted, :internal, "stream_only")
    assert {:ok, true} = Thinking.agent_content_absent?(target)
    assert :ok = Thinking.process_stream_chunk_tainted(target, "only stream", taint)
    assert {:ok, false} = Thinking.agent_content_absent?(target)

    assert :ok = Thinking.delete_agent_content(target)
    assert {:ok, true} = Thinking.agent_content_absent?(target)
  end

  test "public cleanup drops ownership; stale converge keeps provenance", %{target: target} do
    taint = taint(:trusted, :internal, "thinking_stale_converge")

    assert {:ok, entry} =
             Thinking.record_thinking_tainted(target, "stale converge thought", taint)

    assert {:ok, ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert entry.id in ids_before

    pid = Process.whereis(Thinking)
    assert MapSet.member?(:sys.get_state(pid).owned_agents, target)

    assert :ok = Thinking.delete_agent_content(target)
    refute MapSet.member?(:sys.get_state(pid).owned_agents, target)
    refute Map.has_key?(:sys.get_state(pid).streams, target)

    send(pid, {:converge_projection, target})
    _ = :sys.get_state(pid)

    assert {:ok, true} = Thinking.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, target)
  end

  test "malformed durable with ownership armed: public cleanup fails closed, provenance kept",
       %{
         target: target
       } do
    taint = taint(:trusted, :internal, "thinking_malformed")

    assert {:ok, entry} =
             Thinking.record_thinking_tainted(target, "malformed authority thought", taint)

    assert {:ok, ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert MapSet.member?(:sys.get_state(Thinking).owned_agents, target)

    bare = %{"not" => "a_record", "agent" => target}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(@store_name, target, bare)

    assert {:error, del_reason} = Thinking.delete_agent_content(target)
    assert del_reason in @delete_errors
    refute MapSet.member?(:sys.get_state(Thinking).owned_agents, target)

    send(Process.whereis(Thinking), {:converge_projection, target})
    _ = :sys.get_state(Thinking)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert entry.id in ids_before
  end

  test "owner process down returns closed mutation/read errors", %{target: target} do
    taint = taint(:trusted, :internal, "thinking_owner_down")
    assert {:ok, entry} = Thinking.record_thinking_tainted(target, "owner down", taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert entry.id in ids_before

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Thinking)
    assert Process.whereis(Thinking) == nil

    assert {:error, del_reason} = Thinking.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = Thinking.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_thinking!()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = Thinking.delete_agent_content("")
    assert del_reason in @delete_errors
    refute del_reason in [:invalid_payload, :projection_capacity]

    assert {:error, abs_reason} = Thinking.agent_content_absent?(String.duplicate("q", 300))
    assert abs_reason in @absence_errors
  end

  test "compatibility clear still purges provenance", %{target: target} do
    taint = taint(:trusted, :internal, "thinking_clear_compat")
    assert {:ok, entry} = Thinking.record_thinking_tainted(target, "clear me", taint)
    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, target)
    assert entry.id in ids

    assert :ok = Thinking.clear(target)
    assert [] = Thinking.recent_thinking(target)
    assert {:ok, after_ids} = Provenance.list_item_ids(:thinking_entry, target)
    refute entry.id in after_ids
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

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp ensure_thinking! do
    case Process.whereis(Thinking) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Thinking) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> flunk("failed to restart Thinking: #{inspect(other)}")
        end
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
