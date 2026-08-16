defmodule Arbor.Security.CapabilityStoreReproducibilitySecurityRegressionTest do
  @moduledoc """
  E0B2P source-bound SHA-256 epoch; equal source => equal fixture BEAM + epoch;
  source change invalidates a preserved cert.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.CapabilityUri

  @store_source_path Path.expand("../../../lib/arbor/security/capability_store.ex", __DIR__)
  @production_declaration "defmodule Arbor.Security.CapabilityStore do"
  @fixture_declaration "defmodule Arbor.Security.CapabilityStoreReproFixture do"
  @fixture_module Arbor.Security.CapabilityStoreReproFixture
  @cert_epoch_domain "arbor.security.capability_store.cert_epoch.v1"
  @cert_field :__c3a_cert__

  @tag :tmp_dir
  test "security regression: equal CapabilityStore source is reproducible and " <>
         "a source change invalidates a preserved certificate",
       %{tmp_dir: tmp_dir} do
    on_exit(fn -> unload_fixture(@fixture_module) end)

    path = Path.join(tmp_dir, "capability_store_repro_fixture.ex")
    production_source = File.read!(@store_source_path)
    source_v1 = fixture_source(production_source)
    File.write!(path, source_v1)
    assert File.regular?(path)

    valid_state = minimal_valid_current_state()

    beam1 = compile_fixture(path, @fixture_module)
    {epoch1, certified_v1} = extract_epoch(@fixture_module, valid_state)
    assert is_binary(epoch1) and byte_size(epoch1) == 32
    assert epoch1 == expected_epoch(source_v1)
    assert function_exported?(Arbor.Security.CapabilityStore, :code_change, 3)

    beam2 = compile_fixture(path, @fixture_module)
    {epoch2, _certified_v1_again} = extract_epoch(@fixture_module, valid_state)
    assert beam1 == beam2
    assert epoch2 == epoch1

    assert {:reply, {:error, :not_found}, probed_equal} =
             probe_revoke(@fixture_module, certified_v1)

    assert Map.fetch!(probed_equal, @cert_field) == epoch1

    source_v2 = source_v1 <> "\n# e0b2p source revision\n"
    File.write!(path, source_v2)

    beam3 = compile_fixture(path, @fixture_module)
    {epoch3, _certified_v2} = extract_epoch(@fixture_module, valid_state)
    assert beam3 != beam1
    assert epoch3 != epoch1
    assert epoch3 == expected_epoch(source_v2)

    assert {:reply, {:error, :not_found}, probed_stale} =
             probe_revoke(@fixture_module, certified_v1)

    assert Map.fetch!(probed_stale, @cert_field) == epoch3
    refute Map.fetch!(probed_stale, @cert_field) == epoch1
  end

  defp fixture_source(production_source) do
    case String.split(production_source, @production_declaration, parts: 2) do
      [prefix, suffix] ->
        refute String.contains?(suffix, @production_declaration)
        prefix <> @fixture_declaration <> suffix

      _other ->
        flunk("expected a single production CapabilityStore module declaration")
    end
  end

  defp compile_fixture(path, module) do
    unload_fixture(module)

    # Safe: owner-created temp regular file; only rewrite is the fixture module name.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    compiled = Code.compile_file(path)

    case compiled do
      [{^module, beam}] when is_binary(beam) ->
        beam

      other ->
        flunk("expected [{#{inspect(module)}, beam}], got: #{inspect(other)}")
    end
  end

  defp unload_fixture(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end

  defp extract_epoch(module, valid_state) do
    assert {:ok, certified} = module.code_change(0, valid_state, [])
    {Map.fetch!(certified, @cert_field), certified}
  end

  defp probe_revoke(module, preserved) do
    module.handle_call({:revoke, "cap_absent_e0b2p"}, {self(), make_ref()}, preserved)
  end

  defp expected_epoch(source) do
    :crypto.hash(:sha256, [@cert_epoch_domain, <<0>>, source])
  end

  defp minimal_valid_current_state do
    {:ok, cap} =
      Capability.new(resource_uri: "arbor://fs/read/otp-dv", principal_id: "agent_otp_dv")

    key = {cap.principal_id, canonical_resource_for(cap.resource_uri)}

    %{
      by_id: %{cap.id => cap},
      by_principal: %{cap.principal_id => [cap.id]},
      by_resource: %{key => MapSet.new([cap.id])},
      pending_intents: %{},
      by_issuer: %{},
      by_parent: %{},
      by_usage: %{},
      state_version: 1,
      signal_sync: nil,
      stats: %{
        total_granted: 0,
        total_revoked: 0,
        total_expired: 0,
        total_cascade_revoked: 0,
        restore_scanned: 0,
        restore_active: 0,
        restore_expired: 0,
        restore_superseded: 0,
        restore_rejected: 0
      }
    }
  end

  defp canonical_resource_for(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, parsed} -> CapabilityUri.canonical(parsed)
      _ -> uri
    end
  end
end
