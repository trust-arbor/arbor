defmodule Arbor.Signals.Adapters.CapabilityAuthorizerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Signals.Adapters.CapabilityAuthorizer
  alias Arbor.Signals.Config.Testing

  setup do
    Testing.isolate_namespace()
    :ok
  end

  describe "authorize_subscription/2" do
    test "returns :authorized when security module grants access" do
      Testing.put(:security_module, __MODULE__.MockSecurityAllows)

      assert {:ok, :authorized} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module denies access" do
      Testing.put(:security_module, __MODULE__.MockSecurityDenies)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :pending_approval when provider requires approval" do
      Testing.put(:security_module, __MODULE__.MockSecurityPending)

      assert {:error, :pending_approval} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "constructs correct resource URI for topic" do
      Testing.put(:security_module, __MODULE__.MockSecurityCapture)

      CapabilityAuthorizer.authorize_subscription("agent_xyz", :identity)

      assert_received {:authorize_check, "agent_xyz", "arbor://signals/subscribe/identity",
                       :subscribe, []}
    end

    test "returns :no_capability when security module is not loaded" do
      Testing.put(:security_module, This.Module.Does.Not.Exist)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module lacks authorize/4" do
      Testing.put(:security_module, __MODULE__.MockSecurityNoAuthorize)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module raises an error" do
      Testing.put(:security_module, __MODULE__.MockSecurityRaises)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module throws" do
      Testing.put(:security_module, __MODULE__.MockSecurityThrows)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when security module exits" do
      Testing.put(:security_module, __MODULE__.MockSecurityExits)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "returns :no_capability when provider result is malformed" do
      Testing.put(:security_module, __MODULE__.MockSecurityMalformed)

      assert {:error, :no_capability} =
               CapabilityAuthorizer.authorize_subscription("agent_abc", :security)
    end

    test "defaults to nil when not configured" do
      Testing.delete(:security_module)

      assert CapabilityAuthorizer.security_module() == nil
    end

    test "works with atom topics" do
      Testing.put(:security_module, __MODULE__.MockSecurityCapture)

      CapabilityAuthorizer.authorize_subscription("agent_test", :consensus)

      assert_received {:authorize_check, "agent_test", "arbor://signals/subscribe/consensus",
                       :subscribe, []}
    end

    test "forwards raw session_token and drops other opts" do
      Testing.put(:security_module, __MODULE__.MockSecurityCapture)

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
      Testing.put(:security_module, __MODULE__.MockSecurityCapture)

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

  describe "authorize_channel_principal/3" do
    @tag :security_regression
    test "security regression: a caller-marked identity without signed proof is denied" do
      Testing.put(:security_module, __MODULE__.MockSecurityAllows)

      context =
        "agent_channel_spoof"
        |> AuthContext.new()
        |> AuthContext.mark_verified()

      assert {:error, :unauthorized} =
               CapabilityAuthorizer.authorize_channel_principal(context, :send, "chan_test")
    end

    test "signed channel requests are authorized against the bounded channel resource" do
      Testing.put(:security_module, __MODULE__.MockSecurityCapture)
      proof = %{signed: :request}
      context = AuthContext.new("agent_channel", signed_request: proof)
      digest = :crypto.hash(:sha256, "chan_test") |> Base.encode16(case: :lower)

      assert {:ok, "agent_channel"} =
               CapabilityAuthorizer.authorize_channel_principal(context, :send, "chan_test")

      assert_received {:authorize_check, "agent_channel", resource, :send,
                       [signed_request: ^proof, verify_identity: true]}

      assert resource == "arbor://signals/channel/send/" <> digest
    end

    @tag :security_regression
    test "security regression: missing and malformed channel security providers fail closed" do
      context = AuthContext.new("agent_channel", signed_request: %{signed: :request})

      for provider <- [nil, __MODULE__.MockSecurityNoAuthorize, __MODULE__.MockSecurityMalformed] do
        if provider,
          do: Testing.put(:security_module, provider),
          else: Testing.delete(:security_module)

        assert {:error, :unauthorized} =
                 CapabilityAuthorizer.authorize_channel_principal(context, :send, "chan_test")
      end
    end
  end

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
