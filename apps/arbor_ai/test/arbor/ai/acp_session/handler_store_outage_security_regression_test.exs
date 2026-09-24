defmodule Arbor.AI.AcpSession.HandlerStoreOutageSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.AI.AcpSession.Handler

  test "security regression: missing capability store cannot authorize ACP file access" do
    previous = Application.fetch_env(:arbor_ai, :file_guard_module)
    Application.delete_env(:arbor_ai, :file_guard_module)
    owner = Process.whereis(Arbor.Security.CapabilityStore)
    if owner, do: Process.unregister(Arbor.Security.CapabilityStore)

    on_exit(fn ->
      if owner && Process.alive?(owner) && is_nil(Process.whereis(Arbor.Security.CapabilityStore)),
        do: Process.register(owner, Arbor.Security.CapabilityStore)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_ai, :file_guard_module, value)
        :error -> Application.delete_env(:arbor_ai, :file_guard_module)
      end
    end)

    assert {:error, :security_unavailable} =
             Handler.authorize_file("agent_store_outage", "/tmp/synthetic-input", :read)

    assert {:error, :security_unavailable} =
             Handler.authorize_file("agent_store_outage", "/tmp/synthetic-output", :write)
  end
end
