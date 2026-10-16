defmodule Arbor.Actions.TrustAuditRefusalSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Trust.ApplyProfile
  alias Arbor.Trust

  @moduletag :fast

  setup do
    if is_nil(Process.whereis(Arbor.Trust.Store)), do: start_supervised!(Arbor.Trust.Store)

    if is_nil(Process.whereis(Arbor.Trust.Manager)),
      do: start_supervised!({Arbor.Trust.Manager, event_store: false})

    :ok
  end

  test "security regression: restricted durable audit refusal prevents a profile mutation" do
    agent_id = "audit_refusal_#{System.unique_integer([:positive])}"
    assert {:ok, before} = Trust.ensure_trust_profile(agent_id, baseline: :block, rules: %{})
    on_exit(fn -> Trust.delete_trust_profile(agent_id) end)

    assert {:error, message} =
             ApplyProfile.run(
               %{agent_id: agent_id, baseline: "auto", rules: %{"arbor://code/read" => "auto"}},
               %{agent_id: "agent_audit_regression_actor"}
             )

    assert message =~ "restricted_durable_encryption_unavailable"
    assert {:ok, ^before} = Trust.get_trust_profile(agent_id)
  end

  test "security regression: restricted durable audit refusal cannot create a new profile" do
    agent_id = "audit_refusal_new_#{System.unique_integer([:positive])}"
    on_exit(fn -> Trust.delete_trust_profile(agent_id) end)

    assert {:error, _} =
             ApplyProfile.run(
               %{agent_id: agent_id, baseline: "auto", rules: %{}},
               %{agent_id: "agent_audit_regression_actor"}
             )

    assert {:error, :not_found} = Trust.get_trust_profile(agent_id)
  end
end
