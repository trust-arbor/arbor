defmodule Arbor.Trust.CapabilitySyncAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-002,SSEC-004"

  alias Arbor.Trust.{CapabilitySync, Manager, Store}

  @moduletag :fast

  setup do
    ensure_started(Store, persistence: :memory)
    ensure_started(Manager, circuit_breaker: false, decay: false, event_store: false)
    ensure_started(CapabilitySync, enabled: false)

    agent_id = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    {:ok, _profile} = Manager.create_trust_profile(agent_id)

    on_exit(fn ->
      _ = Store.delete_profile(agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  @tag spec: "KSEC-002,SSEC-004"
  test "security regression: public capability sync cannot mint with ambient process authority",
       %{
         agent_id: agent_id
       } do
    assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilitySync.sync_capabilities(agent_id)

    assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
  end

  defp ensure_started(module, opts) do
    case Process.whereis(module) do
      nil -> start_supervised!({module, opts})
      pid -> pid
    end
  end
end
