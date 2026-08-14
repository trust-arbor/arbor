defmodule Arbor.Signals.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Config

  @seams [:durable_sink_module, :security_module, :crypto_module, :identity_registry_module]

  setup do
    originals =
      Map.new(@seams, fn key -> {key, Application.get_env(:arbor_signals, key, :unset)} end)

    on_exit(fn ->
      Enum.each(@seams, fn key -> restore(key, originals[key]) end)
    end)

    :ok
  end

  test "durable sink seam defaults to nil" do
    Application.delete_env(:arbor_signals, :durable_sink_module)
    assert Config.durable_sink_module() == nil
  end

  test "durable sink seam returns the configured module" do
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.FakeSink)
    assert Config.durable_sink_module() == __MODULE__.FakeSink
  end

  test "durable sink seam returns invalid env raw" do
    Application.put_env(:arbor_signals, :durable_sink_module, "not-a-module")
    assert Config.durable_sink_module() == "not-a-module"

    Application.put_env(:arbor_signals, :durable_sink_module, true)
    assert Config.durable_sink_module() == true
  end

  test "security crypto and identity seams default to nil" do
    Application.delete_env(:arbor_signals, :security_module)
    Application.delete_env(:arbor_signals, :crypto_module)
    Application.delete_env(:arbor_signals, :identity_registry_module)

    assert Config.security_module() == nil
    assert Config.crypto_module() == nil
    assert Config.identity_registry_module() == nil
  end

  test "security crypto and identity seams return the configured module" do
    Application.put_env(:arbor_signals, :security_module, __MODULE__.FakeAuth)
    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.FakeCrypto)
    Application.put_env(:arbor_signals, :identity_registry_module, __MODULE__.FakeKeys)

    assert Config.security_module() == __MODULE__.FakeAuth
    assert Config.crypto_module() == __MODULE__.FakeCrypto
    assert Config.identity_registry_module() == __MODULE__.FakeKeys
  end

  test "security crypto and identity seams return invalid env raw" do
    Application.put_env(:arbor_signals, :security_module, "not-a-module")
    Application.put_env(:arbor_signals, :crypto_module, true)
    Application.put_env(:arbor_signals, :identity_registry_module, false)

    assert Config.security_module() == "not-a-module"
    assert Config.crypto_module() == true
    assert Config.identity_registry_module() == false
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_signals, key)
  defp restore(key, value), do: Application.put_env(:arbor_signals, key, value)

  defmodule FakeSink do
  end

  defmodule FakeAuth do
  end

  defmodule FakeCrypto do
  end

  defmodule FakeKeys do
  end
end
