defmodule Arbor.Persistence.EventLogBackendSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Agent, as: AgentEventLog
  alias Arbor.Persistence.EventLog.ETS

  test "security regression: ETS expected_version is an atomic compare-and-append" do
    name = unique_name(:ets_cas_parent_proof)
    start_supervised!({ETS, name: name})

    assert {:ok, [_]} =
             ETS.append("cas", Event.new("cas", "first", %{}),
               name: name,
               expected_version: 0
             )

    assert {:error, :version_conflict} =
             ETS.append("cas", Event.new("cas", "second", %{}),
               name: name,
               expected_version: 0
             )

    assert {:ok, 1} = ETS.stream_version("cas", name: name)
  end

  test "security regression: a queued ETS append cannot commit after its public deadline" do
    name = unique_name(:ets_queue_parent_proof)
    start_supervised!({ETS, name: name})
    :ok = :sys.suspend(name)

    task =
      Task.async(fn ->
        ETS.append("queued", Event.new("queued", "must-not-commit", %{}),
          name: name,
          append_timeout_ms: 20
        )
      end)

    wait_for_queued_call(Process.whereis(name))
    Process.sleep(35)
    :ok = :sys.resume(name)

    assert {:error, {:append_indeterminate, _operation}} = Task.await(task, 1_000)
    assert {:ok, 0} = ETS.stream_version("queued", name: name)
  end

  test "security regression: a queued Agent append cannot commit after its public deadline" do
    name = unique_name(:agent_queue_parent_proof)
    start_supervised!({AgentEventLog, name: name})
    :ok = :sys.suspend(name)

    task =
      Task.async(fn ->
        AgentEventLog.append("queued", Event.new("queued", "must-not-commit", %{}),
          name: name,
          append_timeout_ms: 20
        )
      end)

    wait_for_queued_call(Process.whereis(name))
    Process.sleep(35)
    :ok = :sys.resume(name)

    assert {:error, {:append_indeterminate, _operation}} = Task.await(task, 1_000)
    assert {:ok, 0} = AgentEventLog.stream_version("queued", name: name)
  end

  defp unique_name(prefix),
    do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_for_queued_call(pid, attempts \\ 100)

  defp wait_for_queued_call(_pid, 0), do: flunk("append call was not queued")

  defp wait_for_queued_call(pid, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _not_queued ->
        Process.sleep(1)
        wait_for_queued_call(pid, attempts - 1)
    end
  end
end
