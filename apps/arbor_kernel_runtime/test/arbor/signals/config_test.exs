defmodule Arbor.Signals.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Config
  alias Arbor.Signals.Config.Testing

  setup do
    Testing.isolate_namespace()
    :ok
  end

  test "durable sink seam defaults to nil" do
    Testing.delete(:durable_sink_module)
    assert Config.durable_sink_module() == nil
  end

  test "durable sink seam returns the configured module" do
    Testing.put(:durable_sink_module, __MODULE__.FakeSink)
    assert Config.durable_sink_module() == __MODULE__.FakeSink
  end

  test "durable sink seam returns invalid env raw" do
    Testing.put(:durable_sink_module, "not-a-module")
    assert Config.durable_sink_module() == "not-a-module"

    Testing.put(:durable_sink_module, true)
    assert Config.durable_sink_module() == true
  end

  test "security crypto and identity seams default to nil" do
    Testing.delete(:security_module)
    Testing.delete(:crypto_module)
    Testing.delete(:identity_registry_module)

    assert Config.security_module() == nil
    assert Config.crypto_module() == nil
    assert Config.identity_registry_module() == nil
  end

  test "security crypto and identity seams return the configured module" do
    Testing.put(:security_module, __MODULE__.FakeAuth)
    Testing.put(:crypto_module, __MODULE__.FakeCrypto)
    Testing.put(:identity_registry_module, __MODULE__.FakeKeys)

    assert Config.security_module() == __MODULE__.FakeAuth
    assert Config.crypto_module() == __MODULE__.FakeCrypto
    assert Config.identity_registry_module() == __MODULE__.FakeKeys
  end

  test "security crypto and identity seams return invalid env raw" do
    Testing.put(:security_module, "not-a-module")
    Testing.put(:crypto_module, true)
    Testing.put(:identity_registry_module, false)

    assert Config.security_module() == "not-a-module"
    assert Config.crypto_module() == true
    assert Config.identity_registry_module() == false
  end

  test "kernel values are visible through owner getters" do
    Testing.put(:durable_sink_module, :kernel_only)
    assert Config.durable_sink_module() == :kernel_only

    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "authenticated security-sync transport is false by default and ignores subscriber maps" do
    Testing.delete(:security_sync_subscribers)
    refute Config.authenticated_security_sync_transport?()
    refute Arbor.Signals.authenticated_security_sync_transport?()

    Testing.put(:security_sync_subscribers, %{
      nonce_cache: %{
        owner: Arbor.Security.Identity.NonceCache,
        events: [:nonce_seen]
      }
    })

    assert Config.security_sync_transport_configured?()
    refute Config.authenticated_security_sync_transport?()
    refute Arbor.Signals.authenticated_security_sync_transport?()
  end

  test "configured nil is distinct from a missing start_children key" do
    Testing.put(:start_children, nil)
    assert Config.start_children?() == nil

    Testing.delete(:start_children)
    assert Config.start_children?() == true
  end

  test "configured nil on a nil-default seam is not treated as missing" do
    Testing.put(:durable_sink_module, nil)
    assert Config.durable_sink_module() == nil
  end

  test "namespace snapshot restores missing distinctly from configured nil" do
    Application.delete_env(:arbor_kernel, :signals)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, nil})
    assert Testing.snapshot_namespace() == {:ok, nil}

    Testing.restore_namespace(:error)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, [durable_sink_module: nil]})
    assert Testing.snapshot_namespace() == {:ok, [durable_sink_module: nil]}
    assert Config.durable_sink_module() == nil
  end

  test "test namespace mutations preserve map containers" do
    Testing.restore_namespace({:ok, %{durable_sink_module: :first, untouched: :kept}})
    Testing.put(:durable_sink_module, :second)

    assert Config.durable_sink_module() == :second
    assert Testing.get(:durable_sink_module) == :second
    assert Testing.get(:untouched) == :kept

    Testing.delete(:durable_sink_module)
    assert Testing.get(:durable_sink_module, :missing) == :missing
    assert Testing.get(:untouched) == :kept
  end

  test "malformed namespace containers raise through owner getters" do
    Enum.each([nil, [:not_a_keyword], ~D[2026-08-14]], fn malformed ->
      Testing.restore_namespace({:ok, malformed})

      assert_raise ArgumentError, ~r/malformed :arbor_kernel :signals namespace/, fn ->
        Config.durable_sink_module()
      end
    end)
  end

  defmodule FakeSink do
  end

  defmodule FakeAuth do
  end

  defmodule FakeCrypto do
  end

  defmodule FakeKeys do
  end
end
