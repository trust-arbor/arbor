defmodule Arbor.Agent.ExternalRegistrationSecurityTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.ExternalRegistration

  @moduletag :fast

  test "security regression: a caller without registration authority cannot mint an agent" do
    caller_id = "human_unprivileged_#{System.unique_integer([:positive])}"
    display_name = "Denied external #{System.unique_integer([:positive])}"

    assert {:error, :unauthorized} =
             Arbor.Agent.register_external_agent(
               caller_id,
               display_name,
               "external",
               identity_verified: true
             )

    refute Enum.any?(Arbor.Agent.list_agents(), &(&1.display_name == display_name))
  end

  test "fixed profiles never grant global filesystem wildcards" do
    for type <- Arbor.Agent.external_agent_types() do
      assert {:ok, capabilities} = ExternalRegistration.capabilities_for(type.type)
      resources = Enum.map(capabilities, & &1.resource)

      refute "arbor://fs/read/**" in resources
      refute "arbor://fs/write/**" in resources
    end

    assert {:ok, claude_capabilities} =
             ExternalRegistration.capabilities_for("claude_code")

    claude_resources = Enum.map(claude_capabilities, & &1.resource)
    assert "arbor://fs/read/repo" in claude_resources
    assert "arbor://fs/write/repo" in claude_resources
  end

  test "unknown profiles and ambiguous caller proofs fail closed" do
    assert {:error, :unsupported_agent_type} =
             Arbor.Agent.register_external_agent(
               "human_test",
               "Unknown",
               "not-a-profile",
               identity_verified: true
             )

    assert {:error, :invalid_opts} =
             Arbor.Agent.register_external_agent(
               "human_test",
               "Ambiguous",
               "external",
               identity_verified: true,
               session_token: "token"
             )
  end
end
