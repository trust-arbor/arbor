defmodule Arbor.Common.CapabilityProviders.ActionProviderUriInjectionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.CapabilityProviders.ActionProvider
  alias Arbor.Common.Config.Testing

  setup do
    Testing.isolate_namespace()
    :ok
  end

  test "injected provider URI is stored on the descriptor" do
    Testing.put(:action_capability_uri_module, __MODULE__.InjectedURI)

    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == "arbor://test/injected"
  end

  test "nil provider leaves capability_uri nil" do
    Testing.delete(:action_capability_uri_module)

    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil
  end

  test "non-binary provider return leaves capability_uri nil" do
    Testing.put(:action_capability_uri_module, __MODULE__.NonBinaryURI)

    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil
  end

  test "provider raise, throw, or exit leaves capability_uri nil" do
    Testing.put(:action_capability_uri_module, __MODULE__.RaisingURI)
    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil

    Testing.put(:action_capability_uri_module, __MODULE__.ThrowingURI)
    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil

    Testing.put(:action_capability_uri_module, __MODULE__.ExitingURI)
    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil
  end

  defmodule InjectedURI do
    def canonical_uri_for(_module, _params), do: "arbor://test/injected"
  end

  defmodule NonBinaryURI do
    def canonical_uri_for(_module, _params), do: :error
  end

  defmodule RaisingURI do
    def canonical_uri_for(_module, _params), do: raise("uri boom")
  end

  defmodule ThrowingURI do
    def canonical_uri_for(_module, _params), do: throw(:uri_throw)
  end

  defmodule ExitingURI do
    def canonical_uri_for(_module, _params), do: exit(:uri_exit)
  end
end
