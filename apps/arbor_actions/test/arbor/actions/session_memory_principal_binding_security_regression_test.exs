defmodule Arbor.Actions.SessionMemoryPrincipalBindingSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.SessionMemory

  # 2026-10-11 cross-library review F-009: session_memory.* took the target
  # agent from params, so an agent-authored graph (`pipeline.run` with inline
  # DOT) could index notes into — or recall from — another agent's memory.
  test "security regression (F-009): a params agent_id that differs from the bound principal is refused" do
    assert_raise ArgumentError, ~r/principal_mismatch/, fn ->
      SessionMemory.bind_agent_id!(%{agent_id: "agent_victim"}, %{agent_id: "agent_attacker"})
    end

    assert_raise ArgumentError, ~r/principal_mismatch/, fn ->
      SessionMemory.UpdateWorkingMemory.run(
        %{agent_id: "agent_victim", concerns: ["planted"]},
        %{agent_id: "agent_attacker"}
      )
    end
  end

  test "the bound principal is used when params carry no target or the same target" do
    assert SessionMemory.bind_agent_id!(%{}, %{agent_id: "agent_a"}) == "agent_a"
    assert SessionMemory.bind_agent_id!(%{agent_id: ""}, %{agent_id: "agent_a"}) == "agent_a"

    assert SessionMemory.bind_agent_id!(%{agent_id: "agent_a"}, %{agent_id: "agent_a"}) ==
             "agent_a"

    assert SessionMemory.bind_agent_id!(%{"session.agent_id" => "agent_a"}, %{agent_id: "agent_a"}) ==
             "agent_a"
  end

  test "direct in-VM calls with no bound principal keep the params target (accepted design)" do
    assert SessionMemory.bind_agent_id!(%{agent_id: "agent_b"}, %{}) == "agent_b"
  end
end
