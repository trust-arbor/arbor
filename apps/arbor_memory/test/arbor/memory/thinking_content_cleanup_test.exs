defmodule Arbor.Memory.ThinkingContentCleanupTest do
  @moduledoc """
  Content-only Thinking cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{MemoryStore, Provenance, Thinking}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_thinking

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = Thinking.clear(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      for agent <- [target, child, survivor] do
        _ = Thinking.clear(agent)
        _ = Provenance.delete_agent(agent)
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

    # Unfinished stream for target
    assert :ok = Thinking.process_stream_chunk_tainted(target, "partial stream", taint)
    assert {:ok, false} = Thinking.agent_content_absent?(target)

    assert :ok = Thinking.delete_agent_content(target)
    assert {:ok, true} = Thinking.agent_content_absent?(target)
    assert :ok = Thinking.delete_agent_content(target)
    assert {:ok, true} = Thinking.agent_content_absent?(target)

    # Prove content gone without rehydrate paths that may rewrite live labels.
    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("thinking", target)

    # Stream discarded
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

  test "stale converge_projection after content-only delete does not purge provenance", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "thinking_stale_converge")

    assert {:ok, entry} =
             Thinking.record_thinking_tainted(target, "stale converge thought", taint)

    assert {:ok, ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert entry.id in ids_before

    pid = Process.whereis(Thinking)
    assert is_pid(pid)

    # Queue converge while owned, suspend so it runs only after ownership drop.
    :sys.suspend(pid)
    send(pid, {:converge_projection, target})

    assert :ok = MemoryStore.delete_tainted_authoritative("thinking", target)
    true = :ets.delete(@ets_table, target)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.update!(:owned_agents, &MapSet.delete(&1, target))
      |> Map.update!(:streams, &Map.delete(&1, target))
    end)

    :sys.resume(pid)
    _ = :sys.get_state(pid)

    assert {:ok, true} = Thinking.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, target)

    send(pid, {:converge_projection, target})
    _ = :sys.get_state(pid)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:thinking_entry, target)
    assert {:ok, true} = Thinking.agent_content_absent?(target)
  end

  test "invalid agent id fails closed" do
    assert {:error, :invalid_request} = Thinking.delete_agent_content("")
    assert {:error, :invalid_request} = Thinking.agent_content_absent?(String.duplicate("q", 300))
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
