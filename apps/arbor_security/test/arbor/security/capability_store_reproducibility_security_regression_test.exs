defmodule Arbor.Security.CapabilityStoreReproducibilitySecurityRegressionTest do
  @moduledoc """
  E0B2P source-bound SHA-256 epoch plus loaded CapabilityStore/CapabilityUri
  identities; exclusive scratch; isolated URI reload and purge fail-closed.
  """

  use ExUnit.Case, async: false

  @moduletag security: :regression

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.CapabilityUri

  @store_source_path Path.expand("../../../lib/arbor/security/capability_store.ex", __DIR__)
  @production_declaration "defmodule Arbor.Security.CapabilityStore do"
  @fixture_declaration "defmodule Arbor.Security.CapabilityStoreReproFixture do"
  @production_uri_alias "alias Arbor.Contracts.Security.CapabilityUri"
  @fixture_uri_alias "alias Arbor.Security.CapabilityStoreReproUriFixture, as: CapabilityUri"
  @fixture_module Arbor.Security.CapabilityStoreReproFixture
  @fixture_uri_module Arbor.Security.CapabilityStoreReproUriFixture
  @cert_epoch_domain "arbor.security.capability_store.cert_epoch.v1"
  @cert_field :__c3a_cert__
  @scratch_attempts 16
  @scratch_prefix "e0b2p-capability-store-repro-"

  @tag :slow
  test "security regression: equal CapabilityStore source is reproducible, " <>
         "a source change invalidates a preserved certificate, an isolated " <>
         "validator-dependency reload rejects a stale certificate, and " <>
         "purging that dependency fails closed" do
    tmp_dir = exclusive_scratch_dir!()
    expanded = Path.expand(tmp_dir)
    cwd = Path.expand(File.cwd!())
    assert Path.dirname(expanded) == Path.expand(System.tmp_dir!())
    refute expanded == cwd
    refute String.starts_with?(expanded, cwd <> "/")
    assert File.dir?(tmp_dir)
    assert File.mkdir(tmp_dir) == {:error, :eexist}

    on_exit(fn ->
      unload_fixture(@fixture_module)
      unload_fixture(@fixture_uri_module)
      File.rm_rf!(tmp_dir)
    end)

    uri_path = Path.join(tmp_dir, "capability_uri_repro_fixture.ex")
    path = Path.join(tmp_dir, "capability_store_repro_fixture.ex")
    production_source = File.read!(@store_source_path)
    source_v1 = fixture_source(production_source)
    File.write!(path, source_v1)
    assert File.regular?(path)

    _uri_beam_v1 = compile_dep_fixture(uri_path, @fixture_uri_module, uri_fixture_source(1))
    valid_state = minimal_valid_current_state()

    beam1 = compile_fixture(path, @fixture_module)
    {cert1, certified_v1} = extract_cert(@fixture_module, valid_state)
    source1 = source_identity(cert1)
    assert is_binary(source1) and byte_size(source1) == 32
    assert source1 == expected_epoch(source_v1)
    assert function_exported?(Arbor.Security.CapabilityStore, :code_change, 3)

    beam2 = compile_fixture(path, @fixture_module)
    {cert2, _certified_v1_again} = extract_cert(@fixture_module, valid_state)
    assert beam1 == beam2
    assert cert2 == cert1

    assert {:reply, {:error, :not_found}, probed_equal} =
             probe_revoke(@fixture_module, certified_v1)

    assert Map.fetch!(probed_equal, @cert_field) == cert1

    source_v2 = source_v1 <> "\n# e0b2p source revision\n"
    File.write!(path, source_v2)

    beam3 = compile_fixture(path, @fixture_module)
    {cert3, _certified_v2} = extract_cert(@fixture_module, valid_state)
    assert beam3 != beam1
    assert cert3 != cert1
    assert source_identity(cert3) == expected_epoch(source_v2)

    assert {:reply, {:error, :not_found}, probed_stale} =
             probe_revoke(@fixture_module, certified_v1)

    assert Map.fetch!(probed_stale, @cert_field) == cert3
    refute Map.fetch!(probed_stale, @cert_field) == cert1

    assert File.read!(path) == source_v2
    _uri_beam_v2 = compile_dep_fixture(uri_path, @fixture_uri_module, uri_fixture_source(2))

    assert {:reply, {:error, :not_found}, probed_dep} =
             probe_revoke(@fixture_module, probed_stale)

    # Behavioral: parent source-only cert is unchanged by a URI-fixture reload.
    refute Map.fetch!(probed_dep, @cert_field) == cert3

    {_source3, store_md5_3, uri_md5_3} = cert3
    {source_dep, store_md5_dep, uri_md5_dep} = Map.fetch!(probed_dep, @cert_field)
    assert source_dep == expected_epoch(source_v2)
    assert store_md5_dep == store_md5_3
    assert store_md5_dep == @fixture_module.module_info(:md5)
    assert uri_md5_dep == @fixture_uri_module.module_info(:md5)
    refute uri_md5_dep == uri_md5_3

    unload_fixture(@fixture_uri_module)

    assert {:stop, :certification_identity_unavailable, {:error, :capability_store_unavailable},
            _stopped} = probe_revoke(@fixture_module, probed_dep)
  end

  defp exclusive_scratch_dir! do
    tmp_root = System.tmp_dir!()

    Enum.reduce_while(1..@scratch_attempts, :exhausted, fn _attempt, _acc ->
      suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      path = Path.join(tmp_root, @scratch_prefix <> suffix)

      case File.mkdir(path) do
        :ok -> {:halt, path}
        {:error, :eexist} -> {:cont, :exhausted}
        {:error, _reason} -> {:halt, :mkdir_failed}
      end
    end)
    |> case do
      path when is_binary(path) -> path
      :mkdir_failed -> flunk("exclusive scratch mkdir failed")
      :exhausted -> flunk("exclusive scratch mkdir exhausted bounded retries")
    end
  end

  defp fixture_source(production_source) do
    renamed =
      case String.split(production_source, @production_declaration, parts: 2) do
        [prefix, suffix] ->
          refute String.contains?(suffix, @production_declaration)
          prefix <> @fixture_declaration <> suffix

        _other ->
          flunk("expected a single production CapabilityStore module declaration")
      end

    case String.split(renamed, @production_uri_alias, parts: 2) do
      [prefix, suffix] ->
        refute String.contains?(suffix, @production_uri_alias)
        prefix <> @fixture_uri_alias <> suffix

      _other ->
        flunk("expected a single production CapabilityUri alias")
    end
  end

  defp uri_fixture_source(mark) when mark in [1, 2] do
    """
    defmodule Arbor.Security.CapabilityStoreReproUriFixture do
      @moduledoc false
      def parse(uri), do: Arbor.Contracts.Security.CapabilityUri.parse(uri)
      def canonical(parsed), do: Arbor.Contracts.Security.CapabilityUri.canonical(parsed)
      def prefix_match?(prefix, uri), do: Arbor.Contracts.Security.CapabilityUri.prefix_match?(prefix, uri)
      def mark, do: #{mark}
    end
    """
  end

  defp compile_fixture(path, module) do
    unload_fixture(module)

    # Safe: owner-created temp regular file; only rewrites are the fixture
    # module name and the existing CapabilityUri alias.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    compiled = Code.compile_file(path)

    case compiled do
      [{^module, beam}] when is_binary(beam) ->
        beam

      other ->
        flunk("expected [{#{inspect(module)}, beam}], got: #{inspect(other)}")
    end
  end

  defp compile_dep_fixture(path, module, source) do
    unload_fixture(module)
    File.write!(path, source)

    # Safe: owner-created temp regular file; isolated URI fixture only.
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

  defp extract_cert(module, valid_state) do
    assert {:ok, certified} = module.code_change(0, valid_state, [])
    {Map.fetch!(certified, @cert_field), certified}
  end

  defp source_identity({source, _store, _uri}) when is_binary(source), do: source

  defp source_identity(source) when is_binary(source) and byte_size(source) == 32, do: source

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
