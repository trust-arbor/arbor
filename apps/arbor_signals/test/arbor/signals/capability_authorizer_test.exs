defmodule Arbor.Signals.Adapters.CapabilityAuthorizerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Adapters.CapabilityAuthorizer

  describe "authorize_subscription/2" do
    test "returns :authorized when security module reports capability exists" do
      # Configure a mock security module that says "yes"
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityAllows)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      assert {:ok, :authorized} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module reports no capability" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityDenies)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "constructs correct resource URI for topic" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityCapture)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      CapabilityAuthorizer.authorize_subscription("agent_xyz", :identity)

      assert_received {:can_check, "agent_xyz", "arbor://signals/subscribe/identity", :subscribe}
    end

    test "returns :no_capability when security module is not loaded" do
      Application.put_env(:arbor_signals, :security_module, This.Module.Does.Not.Exist)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module lacks can?/3" do
      # A module that exists but doesn't have can?/3
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityNoCan)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module raises an error" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityRaises)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "defaults to Arbor.Security module when not configured" do
      Application.delete_env(:arbor_signals, :security_module)

      assert CapabilityAuthorizer.security_module() == Arbor.Security
    end

    test "works with atom topics" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityCapture)
      on_exit(fn -> Application.delete_env(:arbor_signals, :security_module) end)

      CapabilityAuthorizer.authorize_subscription("agent_test", :consensus)

      assert_received {:can_check, "agent_test", "arbor://signals/subscribe/consensus", :subscribe}
    end
  end

  # Mock modules for testing

  defmodule MockSecurityAllows do
    def can?(_principal, _resource, _action), do: true
  end

  defmodule MockSecurityDenies do
    def can?(_principal, _resource, _action), do: false
  end

  defmodule MockSecurityCapture do
    def can?(principal, resource, action) do
      send(self(), {:can_check, principal, resource, action})
      true
    end
  end

  defmodule MockSecurityNoCan do
    # Intentionally does not implement can?/3
    def authorize(_principal, _resource, _action), do: {:ok, :authorized}
  end

  defmodule MockSecurityRaises do
    def can?(_principal, _resource, _action) do
      raise "security module error"
    end
  end
end
