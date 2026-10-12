defmodule Arbor.Actions.AgentProfileSelfOnlySecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.AgentProfile.SetDisplayName

  # 2026-10-11 cross-library review F-029: the moduledoc promised "only the
  # agent itself can change its own name", but the target came from params
  # only, so a bare `arbor://agent/profile` cap renamed any agent.
  test "security regression (F-029): a bound principal cannot rename another agent" do
    assert {:error, "Only the agent itself can change its display name"} =
             SetDisplayName.run(
               %{agent_id: "agent_other", display_name: "Impostor"},
               %{agent_id: "agent_self"}
             )
  end
end
