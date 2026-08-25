defmodule Arbor.Agent.Executor.ParkTest do
  @moduledoc """
  Shell-level park path: handle_ask → waiter → resolve_approval.

  Authorizer and Comms are injected through Arbor.Agent.Config (test-owned
  Application env). Runtime intent input cannot select those modules.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Executor
  alias Arbor.Contracts.Memory.Intent

  @script_key {__MODULE__, :auth_script}
  @comms_key {__MODULE__, :comms_result}
  @parent_key {__MODULE__, :parent}

  defmodule StubAuthorizer do
    alias Arbor.Agent.Executor.ParkTest

    def authorize(_agent_id, _resource, _action, _opts) do
      case :persistent_term.get(ParkTest.script_key(), []) do
        [next | rest] ->
          :persistent_term.put(ParkTest.script_key(), rest)
          next

        [] ->
          {:error, :stub_exhausted}
      end
    end
  end

  defmodule StubComms do
    alias Arbor.Agent.Executor.ParkTest

    def await_interaction_response(request_id, agent_id, _opts) do
      parent = :persistent_term.get(ParkTest.parent_key(), nil)

      if is_pid(parent) do
        send(parent, {:awaited, request_id, agent_id})
      end

      :persistent_term.get(ParkTest.comms_key(), {:ok, :approved, %{}})
    end
  end

  def script_key, do: @script_key
  def comms_key, do: @comms_key
  def parent_key, do: @parent_key

  setup do
    original_authorizer = Application.get_env(:arbor_agent, :executor_authorizer)
    original_await = Application.get_env(:arbor_agent, :executor_interaction_await)

    Application.put_env(:arbor_agent, :executor_authorizer, StubAuthorizer)
    Application.put_env(:arbor_agent, :executor_interaction_await, StubComms)
    :persistent_term.put(@parent_key, self())

    agent_id = "executor-park-#{System.unique_integer([:positive])}"
    Executor.stop(agent_id)

    on_exit(fn ->
      Executor.stop(agent_id)
      restore_env(:executor_authorizer, original_authorizer)
      restore_env(:executor_interaction_await, original_await)
      :persistent_term.erase(@script_key)
      :persistent_term.erase(@comms_key)
      :persistent_term.erase(@parent_key)
    end)

    {:ok, agent_id: agent_id}
  end

  test "security regression: pending_approval parks until Comms grants, then resumes", %{
    agent_id: agent_id
  } do
    :persistent_term.put(@script_key, [
      {:ok, :pending_approval, "irq_park_grant"},
      {:ok, :authorized}
    ])

    :persistent_term.put(@comms_key, {:ok, :approved, %{}})

    {:ok, _pid} = Executor.start(agent_id, approval_timeout_ms: 500)
    intent = act_intent("int_park_grant")
    assert :ok = Executor.execute(agent_id, intent)

    assert_receive {:awaited, "irq_park_grant", ^agent_id}, 500

    status =
      wait_until(fn ->
        {:ok, s} = Executor.status(agent_id)
        if s.awaiting_count == 0 and s.stats.intents_executed == 1, do: {:ok, s}, else: :retry
      end)

    assert status.stats.intents_parked == 1
    assert status.stats.intents_blocked == 0
    assert :persistent_term.get(@script_key) == []
  end

  test "parked intent fails closed when Comms denies", %{agent_id: agent_id} do
    :persistent_term.put(@script_key, [{:ok, :pending_approval, "irq_park_deny"}])
    :persistent_term.put(@comms_key, {:ok, :denied, %{}})

    {:ok, _pid} = Executor.start(agent_id, approval_timeout_ms: 500)
    intent = act_intent("int_park_deny")
    assert :ok = Executor.execute(agent_id, intent)

    assert_receive {:awaited, "irq_park_deny", ^agent_id}, 500

    status =
      wait_until(fn ->
        {:ok, s} = Executor.status(agent_id)
        if s.awaiting_count == 0 and s.stats.intents_blocked == 1, do: {:ok, s}, else: :retry
      end)

    assert status.stats.intents_parked == 1
    assert status.stats.intents_executed == 0
  end

  test "a second :ask after grant does not loop", %{agent_id: agent_id} do
    :persistent_term.put(@script_key, [
      {:ok, :pending_approval, "irq_park_again"},
      {:ok, :pending_approval, "irq_park_again"}
    ])

    :persistent_term.put(@comms_key, {:ok, :approved, %{}})

    {:ok, _pid} = Executor.start(agent_id, approval_timeout_ms: 500)
    intent = act_intent("int_park_again")
    assert :ok = Executor.execute(agent_id, intent)

    assert_receive {:awaited, "irq_park_again", ^agent_id}, 500

    status =
      wait_until(fn ->
        {:ok, s} = Executor.status(agent_id)
        if s.awaiting_count == 0 and s.stats.intents_blocked == 1, do: {:ok, s}, else: :retry
      end)

    assert status.stats.intents_parked == 1
    assert status.stats.intents_executed == 0
    refute_received {:awaited, _, _}
  end

  defp act_intent(id) do
    Intent.action(:park_probe_unknown_action, %{path: "/tmp/park"},
      id: id,
      created_at: ~U[2026-08-25 00:00:00Z]
    )
  end

  defp wait_until(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_loop(fun, deadline)
  end

  defp wait_until_loop(fun, deadline) do
    case fun.() do
      {:ok, result} ->
        result

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for executor park settlement")
        else
          Process.sleep(10)
          wait_until_loop(fun, deadline)
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_agent, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_agent, key, value)
end
