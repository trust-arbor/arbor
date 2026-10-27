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

  test "package values are visible through owner getters" do
    Testing.put(:durable_sink_module, :package_only)
    assert Config.durable_sink_module() == :package_only

    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "authenticated security-sync transport is false by default and ignores subscriber maps" do
    Testing.delete(:security_sync_subscribers)
    refute Config.authenticated_security_sync_transport?()
    refute Arbor.Signals.authenticated_security_sync_transport?()

    Testing.put(:security_sync_subscribers, %{
      nonce_cache: %{
        owner: __MODULE__.FakeSecuritySyncOwner,
        supervisor: {:application, :arbor_security},
        child_id: __MODULE__.FakeSecuritySyncOwner,
        events: [:nonce_seen]
      }
    })

    assert Config.security_sync_transport_configured?()

    assert {:ok,
            %{
              owner: __MODULE__.FakeSecuritySyncOwner,
              supervisor: {:application, :arbor_security},
              child_id: __MODULE__.FakeSecuritySyncOwner
            }} = Config.security_sync_owner_provenance(:nonce_cache, :nonce_seen)

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

  test "flat application snapshot preserves missing and explicitly configured nil keys" do
    Testing.delete(:durable_sink_module)
    original = Testing.snapshot_namespace()
    refute Keyword.has_key?(original, :durable_sink_module)

    Testing.put(:durable_sink_module, nil)
    snapshot = Testing.snapshot_namespace()
    assert Keyword.fetch!(snapshot, :durable_sink_module) == nil

    Testing.put(:durable_sink_module, :changed)
    Testing.put(:temporary_key, :must_be_removed)
    assert :ok = Testing.restore_namespace(snapshot)
    assert Testing.get(:durable_sink_module, :missing) == nil
    assert Testing.get(:temporary_key, :missing) == :missing

    assert :ok = Testing.restore_namespace(original)
    assert Testing.get(:durable_sink_module, :missing) == :missing
  end

  test "retired kernel namespace is not a second configuration authority" do
    prior = Application.fetch_env(:arbor_kernel, :signals)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbor_kernel, :signals, value)
        :error -> Application.delete_env(:arbor_kernel, :signals)
      end
    end)

    Testing.delete(:durable_sink_module)
    Application.put_env(:arbor_kernel, :signals, durable_sink_module: :retired_provider)
    assert Config.durable_sink_module() == nil

    Testing.put(:durable_sink_module, :package_provider)
    assert Config.durable_sink_module() == :package_provider
  end

  test "test snapshot restoration rejects malformed containers" do
    assert_raise ArgumentError, fn -> Testing.restore_namespace([:not_a_keyword]) end
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
