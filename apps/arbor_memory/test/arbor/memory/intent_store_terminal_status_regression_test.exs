defmodule Arbor.Memory.IntentStoreTerminalStatusRegressionTest do
  @moduledoc """
  M0 regressions from the 2026-10-07 mind/body review
  (.arbor/decisions/2026-10-07-mind-body-sensorium.md):

    * D5 — `fail_intent/3` reopened completed intents, returned refused
      intents to `:pending` for automatic retry, and left retry-exhausted
      intents as hidden `:pending` zombies that stalled goal decomposition.
    * D8 — the store evicted live (non-completed) intents silently.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Memory.IntentStore
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast

  setup do
    start_supervised!(
      {BufferedStore, name: :arbor_memory_durable, backend: nil, write_mode: :sync}
    )

    agent_id = "terminal_status_agent_#{System.unique_integer([:positive])}"
    on_exit(fn -> IntentStore.clear(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "fail_intent/3 never reopens a terminal intent" do
    test "regression: a late failure does not reopen a completed intent", %{agent_id: agent_id} do
      intent = record!(agent_id, goal_id: "goal_late_failure")
      assert {:ok, _} = IntentStore.lock_intent(agent_id, intent.id)
      assert :ok = IntentStore.complete_intent(agent_id, intent.id)

      assert {:error, :intent_terminal} = IntentStore.fail_intent(agent_id, intent.id, "late")

      assert status_of(agent_id, intent.id) == :completed
      refute routable?(agent_id, intent.id)
    end

    test "a failure does not reopen a blocked intent", %{agent_id: agent_id} do
      intent = record!(agent_id)
      assert :ok = IntentStore.block_intent(agent_id, intent.id, "blocked: :unauthorized")

      assert {:error, :intent_terminal} = IntentStore.fail_intent(agent_id, intent.id, "late")
      assert status_of(agent_id, intent.id) == :blocked
    end
  end

  describe "block_intent/3" do
    test "a blocked intent is never routed again", %{agent_id: agent_id} do
      intent = record!(agent_id, goal_id: "goal_blocked")
      assert {:ok, _} = IntentStore.lock_intent(agent_id, intent.id)

      assert :ok = IntentStore.block_intent(agent_id, intent.id, "blocked: :unauthorized")

      assert {:ok, _intent, status} = IntentStore.get_intent(agent_id, intent.id)
      assert status.status == :blocked
      assert status.last_failure_reason == "blocked: :unauthorized"
      assert status.retry_count == 0

      refute routable?(agent_id, intent.id)
      assert {:error, :not_lockable} = IntentStore.lock_intent(agent_id, intent.id)
      assert IntentStore.unlock_stale_intents(agent_id, 1) == 0
      assert IntentStore.pending_intents_for_goal(agent_id, "goal_blocked") == []
    end

    test "does not reopen a completed intent", %{agent_id: agent_id} do
      intent = record!(agent_id)
      assert :ok = IntentStore.complete_intent(agent_id, intent.id)

      assert {:error, :intent_terminal} = IntentStore.block_intent(agent_id, intent.id, "late")
      assert status_of(agent_id, intent.id) == :completed
    end

    test "unknown intents are not found", %{agent_id: agent_id} do
      assert {:error, :not_found} = IntentStore.block_intent(agent_id, "int_missing", "x")
    end
  end

  describe "automatic retries are bounded" do
    test "regression: exhausting retries blocks the intent instead of leaving a pending zombie",
         %{agent_id: agent_id} do
      intent = record!(agent_id, goal_id: "goal_exhausted")

      for _attempt <- 1..5 do
        assert {:ok, _retry_count} = IntentStore.fail_intent(agent_id, intent.id, "boom")
      end

      assert {:ok, _intent, status} = IntentStore.get_intent(agent_id, intent.id)
      assert status.status == :blocked
      assert status.retry_count == 5
      assert String.starts_with?(status.last_failure_reason, "retries_exhausted: ")

      refute routable?(agent_id, intent.id)
      # The zombie used to stall decomposition: still "pending for the goal".
      assert IntentStore.pending_intents_for_goal(agent_id, "goal_exhausted") == []
    end

    test "a failure below the ceiling returns the intent to pending", %{agent_id: agent_id} do
      intent = record!(agent_id)

      assert {:ok, 1} = IntentStore.fail_intent(agent_id, intent.id, "transient")
      assert status_of(agent_id, intent.id) == :pending
      assert routable?(agent_id, intent.id)
    end
  end

  describe "prune_stale/2" do
    test "prunes blocked intents once the block itself is stale", %{agent_id: agent_id} do
      intent = record!(agent_id)
      assert :ok = IntentStore.block_intent(agent_id, intent.id, "blocked")

      Process.sleep(20)
      assert IntentStore.prune_stale(agent_id, 5) == 1
      assert {:error, :not_found} = IntentStore.get_intent(agent_id, intent.id)
    end

    test "ages a blocked intent from the block, not from creation", %{agent_id: agent_id} do
      created_at = DateTime.add(DateTime.utc_now(), -3_600, :second)
      intent = record!(agent_id, created_at: created_at)
      assert :ok = IntentStore.block_intent(agent_id, intent.id, "blocked just now")

      assert IntentStore.prune_stale(agent_id, 60_000) == 0
      assert status_of(agent_id, intent.id) == :blocked
    end
  end

  describe "eviction of live intents is never silent" do
    test "regression: evicting a pending intent past the buffer logs a warning",
         %{agent_id: agent_id} do
      [oldest | _] = intents = for n <- 1..100, do: record!(agent_id, id: "int_evict_#{n}")
      assert length(intents) == 100

      log =
        capture_log(fn ->
          record!(agent_id, id: "int_evict_overflow")
        end)

      assert log =~ "IntentStore evicted non-completed intent #{oldest.id}"
      assert log =~ "status=pending"
      assert log =~ "cause=buffer_size"
      assert {:error, :not_found} = IntentStore.get_intent(agent_id, oldest.id)
    end

    test "evicting a completed intent is routine and does not warn", %{agent_id: agent_id} do
      [oldest | _] = for n <- 1..100, do: record!(agent_id, id: "int_done_#{n}")
      assert :ok = IntentStore.complete_intent(agent_id, oldest.id)

      log =
        capture_log(fn ->
          record!(agent_id, id: "int_done_overflow")
        end)

      refute log =~ "IntentStore evicted non-completed intent"
    end
  end

  defp record!(agent_id, opts \\ []) do
    intent =
      Intent.action(:file_read, %{path: "/tmp/x"},
        id: opts[:id],
        goal_id: opts[:goal_id],
        created_at: opts[:created_at]
      )

    assert {:ok, recorded} = IntentStore.record_intent(agent_id, intent)
    recorded
  end

  defp status_of(agent_id, intent_id) do
    assert {:ok, _intent, status} = IntentStore.get_intent(agent_id, intent_id)
    status.status
  end

  defp routable?(agent_id, intent_id) do
    agent_id
    |> IntentStore.pending_intentions(limit: 100)
    |> Enum.any?(fn {intent, _status} -> intent.id == intent_id end)
  end
end
