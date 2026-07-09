defmodule Arbor.Agent.APIAgentCallerLivenessTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.APIAgent

  test "a queued query does not execute after its caller dies" do
    caller = spawn(fn -> :ok end)
    ref = Process.monitor(caller)
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}

    state = %{sentinel: :unchanged}

    assert {:reply, {:error, :caller_gone}, ^state} =
             APIAgent.handle_call(
               {:query, "cancelled work", [task_id: "task_cancelled"]},
               {caller, make_ref()},
               state
             )
  end
end
