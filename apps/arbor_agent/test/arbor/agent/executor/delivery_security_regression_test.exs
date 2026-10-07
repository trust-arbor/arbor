defmodule Arbor.Agent.Executor.DeliverySecurityRegressionTest do
  @moduledoc """
  M0 security regressions from the 2026-10-07 mind/body review
  (.arbor/decisions/2026-10-07-mind-body-sensorium.md).

  Intent delivery to the Executor is at-least-once:
  `ExecutorIntegration.route_pending_intentions/2` re-routes any IntentStore
  lock older than 60 s, including intents the Executor has parked for human
  approval (up to 15 min) and acts that are still running.

    * D4 — a re-delivered parked intent was re-authorized, hit
      `:still_requires_approval`, and was failed; the human's answer to the
      original approval request was then discarded. A re-delivered finished
      intent was executed again.
    * D5 — refused intents were failed back to `:pending` and retried
      automatically; an unauthorized sender could mutate a stored intent by
      reusing its id.

  The authorizer stub behaves like `Arbor.Trust.authorize/4` for an
  `:ask`-gated resource: it answers `:pending_approval` (with a fresh request
  id per call) until the test marks the action approved, then `:authorized`.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Executor
  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Memory.IntentStore

  @mode_key {__MODULE__, :auth_mode}
  @calls_key {__MODULE__, :auth_calls}
  @parent_key {__MODULE__, :parent}

  defmodule TrustLikeAuthorizer do
    alias Arbor.Agent.Executor.DeliverySecurityRegressionTest, as: T

    def authorize(_agent_id, _resource, _action, _opts) do
      calls = :persistent_term.get(T.calls_key(), 0) + 1
      :persistent_term.put(T.calls_key(), calls)

      case :persistent_term.get(T.mode_key(), :ask_until_approved) do
        :ask_until_approved -> {:ok, :pending_approval, "irq_delivery_#{calls}"}
        :approved -> {:ok, :authorized}
        {:deny, reason} -> {:error, reason}
      end
    end
  end

  defmodule HeldComms do
    alias Arbor.Agent.Executor.DeliverySecurityRegressionTest, as: T

    # Parks the approval waiter until the test releases it.
    def await_interaction_response(request_id, _agent_id, _opts) do
      send(:persistent_term.get(T.parent_key()), {:waiter, self(), request_id})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  def mode_key, do: @mode_key
  def calls_key, do: @calls_key
  def parent_key, do: @parent_key

  setup do
    original_authorizer = Application.get_env(:arbor_agent, :executor_authorizer)
    original_await = Application.get_env(:arbor_agent, :executor_interaction_await)

    Application.put_env(:arbor_agent, :executor_authorizer, TrustLikeAuthorizer)
    Application.put_env(:arbor_agent, :executor_interaction_await, HeldComms)
    :persistent_term.put(@parent_key, self())
    :persistent_term.put(@mode_key, :ask_until_approved)
    :persistent_term.put(@calls_key, 0)

    agent_id = "agent_m0_delivery_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Executor.stop(agent_id)
      IntentStore.clear(agent_id)
      restore_env(:executor_authorizer, original_authorizer)
      restore_env(:executor_interaction_await, original_await)
      for key <- [@mode_key, @calls_key, @parent_key], do: :persistent_term.erase(key)
    end)

    {:ok, agent_id: agent_id}
  end

  test "security regression: re-delivering a parked intent neither fails it nor discards the human's approval",
       %{agent_id: agent_id} do
    {:ok, _pid} = Executor.start(agent_id, approval_timeout_ms: 5_000)
    intent = act_intent("int_m0_parked")

    assert :ok = Executor.execute(agent_id, intent)
    assert_receive {:waiter, waiter, "irq_delivery_1"}, 1_000
    await_stats(agent_id, &(&1.awaiting_count == 1))

    # The stale-lock sweep re-routes the same intent while it is parked.
    assert :ok = Executor.execute(agent_id, intent)
    await_stats(agent_id, &(&1.stats.intents_received == 2))

    {:ok, parked} = Executor.status(agent_id)
    assert parked.awaiting_count == 1
    assert parked.stats.intents_blocked == 0
    refute_received {:waiter, _, _}, "duplicate delivery opened a second approval request"

    # The human approves the ORIGINAL request.
    :persistent_term.put(@mode_key, :approved)
    send(waiter, {:release, {:ok, :approved, %{}}})

    done = await_stats(agent_id, &(&1.awaiting_count == 0 and &1.stats.intents_executed == 1))
    assert done.stats.intents_blocked == 0
    # One authorize when parking, one after the approval — none for the duplicate.
    assert :persistent_term.get(@calls_key) == 2
  end

  test "security regression: re-delivering a completed store-managed intent does not execute it again",
       %{agent_id: agent_id} do
    :persistent_term.put(@mode_key, :approved)
    intent = store_locked_intent!(agent_id, "int_m0_completed")
    assert :ok = Arbor.Memory.complete_intent(agent_id, intent.id)

    {:ok, _pid} = Executor.start(agent_id)
    assert :ok = Executor.execute(agent_id, intent)
    status = await_stats(agent_id, &(&1.stats.intents_received == 1))

    assert status.stats.intents_executed == 0
    assert :persistent_term.get(@calls_key) == 0
    assert {:ok, _intent, %{status: :completed}} = Arbor.Memory.get_intent(agent_id, intent.id)
  end

  test "a locked store-managed intent is delivered (positive control)", %{agent_id: agent_id} do
    :persistent_term.put(@mode_key, :approved)
    intent = store_locked_intent!(agent_id, "int_m0_locked")

    {:ok, _pid} = Executor.start(agent_id)
    assert :ok = Executor.execute(agent_id, intent)

    await_stats(agent_id, &(&1.stats.intents_executed == 1))
    assert :persistent_term.get(@calls_key) == 1
  end

  test "security regression: a refused intent is blocked in the store, not re-queued for retry",
       %{agent_id: agent_id} do
    :persistent_term.put(@mode_key, {:deny, :unauthorized})
    intent = store_locked_intent!(agent_id, "int_m0_refused")

    {:ok, _pid} = Executor.start(agent_id)
    assert :ok = Executor.execute(agent_id, intent)
    await_stats(agent_id, &(&1.stats.intents_blocked == 1))

    assert {:ok, _intent, status} = Arbor.Memory.get_intent(agent_id, intent.id)
    assert status.status == :blocked
    assert status.retry_count == 0

    refute Enum.any?(Arbor.Memory.pending_intentions(agent_id), fn {i, _} -> i.id == intent.id end)
  end

  test "an oversized refusal reason still blocks the intent", %{agent_id: agent_id} do
    :persistent_term.put(@mode_key, {:deny, {:huge, String.duplicate("x", 10_000)}})
    intent = store_locked_intent!(agent_id, "int_m0_huge_reason")

    {:ok, _pid} = Executor.start(agent_id)
    assert :ok = Executor.execute(agent_id, intent)
    await_stats(agent_id, &(&1.stats.intents_blocked == 1))

    assert {:ok, _intent, %{status: :blocked}} = Arbor.Memory.get_intent(agent_id, intent.id)
  end

  test "security regression: an unauthorized sender cannot mutate a stored intent or prompt an approval",
       %{agent_id: agent_id} do
    stored = act_intent("int_m0_victim")
    assert {:ok, _} = Arbor.Memory.record_intent(agent_id, stored)

    forged = %{stored | metadata: %{source_agent: "agent_m0_intruder"}}

    {:ok, _pid} = Executor.start(agent_id)
    assert :ok = Executor.execute(agent_id, forged)
    await_stats(agent_id, &(&1.stats.intents_blocked == 1))

    assert {:ok, _intent, status} = Arbor.Memory.get_intent(agent_id, stored.id)
    assert status.status == :pending
    assert Map.get(status, :retry_count, 0) == 0
    # The forged intent never reached the authorizer (which can open approvals).
    assert :persistent_term.get(@calls_key) == 0
    refute_received {:waiter, _, _}
  end

  defp store_locked_intent!(agent_id, id) do
    intent = act_intent(id)
    assert {:ok, _} = Arbor.Memory.record_intent(agent_id, intent)
    assert {:ok, locked} = Arbor.Memory.lock_intent(agent_id, intent.id)
    locked
  end

  defp act_intent(id) do
    Intent.action(:park_probe_unknown_action, %{path: "/tmp/m0"},
      id: id,
      created_at: DateTime.utc_now()
    )
  end

  defp await_stats(agent_id, ready?, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_stats_loop(agent_id, ready?, deadline)
  end

  defp await_stats_loop(agent_id, ready?, deadline) do
    {:ok, status} = Executor.status(agent_id)

    cond do
      ready?.(status) ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for executor state; last status: #{inspect(status)}")

      true ->
        Process.sleep(10)
        await_stats_loop(agent_id, ready?, deadline)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_agent, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_agent, key, value)
end
