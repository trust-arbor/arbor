defmodule Arbor.Signals.Adapters.CapabilityAuthorizerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Adapters.CapabilityAuthorizer

  setup do
    original = Application.get_env(:arbor_signals, :security_module, :unset)
    on_exit(fn -> restore(:security_module, original) end)
    :ok
  end

  describe "authorize_subscription/2" do
    test "returns :authorized when security module grants access" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityAllows)

      assert {:ok, :authorized} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module denies access" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityDenies)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :pending_approval when provider requires approval" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityPending)

      assert {:error, :pending_approval} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "constructs correct resource URI for topic" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityCapture)

      CapabilityAuthorizer.authorize_subscription("agent_xyz", :identity)

      assert_received {:authorize_check, "agent_xyz", "arbor://signals/subscribe/identity",
                       :subscribe, []}
    end

    test "returns :no_capability when security module is not loaded" do
      Application.put_env(:arbor_signals, :security_module, This.Module.Does.Not.Exist)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module lacks authorize/4" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityNoAuthorize)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module raises an error" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityRaises)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module throws" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityThrows)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module exits" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityExits)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when provider result is malformed" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityMalformed)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "defaults to nil when not configured" do
      Application.delete_env(:arbor_signals, :security_module)

      assert CapabilityAuthorizer.security_module() == nil
    end

    test "works with atom topics" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityCapture)

      CapabilityAuthorizer.authorize_subscription("agent_test", :consensus)

      assert_received {:authorize_check, "agent_test", "arbor://signals/subscribe/consensus",
                       :subscribe, []}
    end

    test "forwards raw session_token and drops other opts" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityCapture)

      CapabilityAuthorizer.authorize_subscription("human_abc", :security,
        session_token: "raw-token",
        verify_identity: false,
        identity_verified: true,
        principal_id: "ignored",
        async: true
      )

      assert_received {:authorize_check, "human_abc", "arbor://signals/subscribe/security",
                       :subscribe, opts}

      assert opts == [session_token: "raw-token"]
      refute Keyword.has_key?(opts, :verify_identity)
    end

    test "forwards nil empty and duplicate session tokens raw" do
      Application.put_env(:arbor_signals, :security_module, __MODULE__.MockSecurityCapture)

      CapabilityAuthorizer.authorize_subscription("human_abc", :security, session_token: nil)

      assert_received {:authorize_check, "human_abc", _, :subscribe, [session_token: nil]}

      CapabilityAuthorizer.authorize_subscription("human_abc", :security, session_token: "")

      assert_received {:authorize_check, "human_abc", _, :subscribe, [session_token: ""]}

      CapabilityAuthorizer.authorize_subscription("human_abc", :security,
        session_token: "a",
        session_token: "b"
      )

      assert_received {:authorize_check, "human_abc", _, :subscribe,
                       [session_token: "a", session_token: "b"]}
    end
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_signals, key)
  defp restore(key, value), do: Application.put_env(:arbor_signals, key, value)

  defmodule MockSecurityAllows do
    def authorize(_principal, _resource, _action, _opts \\ []), do: {:ok, :authorized}
  end

  defmodule MockSecurityDenies do
    def authorize(_principal, _resource, _action, _opts \\ []), do: {:error, :denied}
  end

  defmodule MockSecurityPending do
    def authorize(_principal, _resource, _action, _opts \\ []),
      do: {:ok, :pending_approval, "approval_1"}
  end

  defmodule MockSecurityCapture do
    def authorize(principal, resource, action, opts \\ []) do
      send(self(), {:authorize_check, principal, resource, action, opts})
      {:ok, :authorized}
    end
  end

  defmodule MockSecurityNoAuthorize do
    def some_other_function, do: :ok
  end

  defmodule MockSecurityRaises do
    def authorize(_principal, _resource, _action, _opts \\ []) do
      raise "security module error"
    end
  end

  defmodule MockSecurityThrows do
    def authorize(_principal, _resource, _action, _opts \\ []) do
      throw(:security_module_throw)
    end
  end

  defmodule MockSecurityExits do
    def authorize(_principal, _resource, _action, _opts \\ []) do
      exit(:security_module_exit)
    end
  end

  defmodule MockSecurityMalformed do
    def authorize(_principal, _resource, _action, _opts \\ []), do: :ok
  end
end
