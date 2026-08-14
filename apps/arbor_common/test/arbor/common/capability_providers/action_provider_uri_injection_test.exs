defmodule Arbor.Common.CapabilityProviders.ActionProviderUriInjectionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.CapabilityProviders.ActionProvider

  setup do
    original = Application.get_env(:arbor_common, :action_capability_uri_module, :unset)

    on_exit(fn -> restore(:action_capability_uri_module, original) end)

    :ok
  end

  test "injected provider URI is stored on the descriptor" do
    Application.put_env(
      :arbor_common,
      :action_capability_uri_module,
      __MODULE__.InjectedURI
    )

    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == "arbor://test/injected"
  end

  test "nil provider leaves capability_uri nil" do
    Application.delete_env(:arbor_common, :action_capability_uri_module)

    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil
  end

  test "non-binary provider return leaves capability_uri nil" do
    Application.put_env(
      :arbor_common,
      :action_capability_uri_module,
      __MODULE__.NonBinaryURI
    )

    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil
  end

  test "provider raise, throw, or exit leaves capability_uri nil" do
    Application.put_env(:arbor_common, :action_capability_uri_module, __MODULE__.RaisingURI)
    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil

    Application.put_env(:arbor_common, :action_capability_uri_module, __MODULE__.ThrowingURI)
    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil

    Application.put_env(:arbor_common, :action_capability_uri_module, __MODULE__.ExitingURI)
    desc = ActionProvider.module_to_descriptor("file.read", :fake_action, %{})
    assert desc.metadata.capability_uri == nil
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_common, key)
  defp restore(key, value), do: Application.put_env(:arbor_common, key, value)

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
