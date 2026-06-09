defmodule Arbor.Security.CapabilityStore.SerializerTest do
  @moduledoc """
  Serializer round-trip + the C11 backward-compat guard.

  C11 removed the dead top-level `Capability.signature` field (distinct from
  the live `issuer_signature`). Capabilities persisted before that change
  carry a `"signature"` key in their JSON; deserialization must tolerate and
  ignore it, and a current round-trip must preserve every live field without
  reintroducing `signature`.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.SystemAuthority

  setup do
    if Process.whereis(SystemAuthority) == nil and Process.whereis(Arbor.Security.Supervisor) do
      for child <- [{Arbor.Security.Identity.Registry, []}, {SystemAuthority, []}] do
        try do
          Supervisor.start_child(Arbor.Security.Supervisor, child)
        catch
          :exit, _ -> :ok
        end
      end
    end

    :ok
  end

  test "serialize/deserialize round-trip preserves live fields" do
    {:ok, cap} =
      Capability.new(
        resource_uri: "arbor://fs/read/project/**",
        principal_id: "agent_roundtrip",
        constraints: %{rate_limit: 5},
        metadata: %{provenance: %{source: :caps_file}},
        allowed_delegatees: ["agent_b"],
        principal_scope: "human_op"
      )

    {:ok, restored} = Serializer.deserialize(Serializer.serialize(cap))

    assert restored.resource_uri == cap.resource_uri
    assert restored.principal_id == cap.principal_id
    assert restored.constraints == cap.constraints
    assert restored.metadata == cap.metadata
    assert restored.allowed_delegatees == cap.allowed_delegatees
    assert restored.principal_scope == cap.principal_scope
  end

  test "serialized map no longer contains a top-level signature key (C11)" do
    {:ok, cap} = Capability.new(resource_uri: "arbor://fs/read/x", principal_id: "agent_x")
    serialized = Serializer.serialize(cap)

    refute Map.has_key?(serialized, "signature")
    assert Map.has_key?(serialized, "issuer_signature")
  end

  test "legacy JSON carrying a signature key still deserializes (ignored)" do
    # Shape a pre-C11 persisted record: every current key PLUS the dead
    # "signature" field. Deserialization must ignore the extra key.
    legacy = %{
      "id" => "cap_legacy_1",
      "resource_uri" => "arbor://fs/read/legacy",
      "principal_id" => "agent_legacy",
      "granted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "delegation_depth" => 3,
      "constraints" => %{},
      "signature" => Base.encode64("dead-legacy-signature-bytes"),
      "issuer_signature" => nil,
      "delegation_chain" => [],
      "metadata" => %{}
    }

    assert {:ok, cap} = Serializer.deserialize(legacy)
    assert cap.resource_uri == "arbor://fs/read/legacy"
    refute Map.has_key?(Map.from_struct(cap), :signature)
  end

  test "a SIGNED scoped cap still verifies after a persistence round-trip (C1 follow-up)" do
    # principal_scope is signature-covered (C1). If the serializer drops it,
    # the reloaded cap's recomputed payload differs from what was signed and
    # verification fails — silently losing the user binding. This pins that
    # the round-trip preserves the signed fields.
    {:ok, cap} =
      Capability.new(
        resource_uri: "arbor://fs/write/Users/x/scoped/**",
        principal_id: "agent_scoped",
        principal_scope: "human_operator",
        allowed_delegatees: ["agent_a"],
        metadata: %{provenance: %{source: :caps_file}}
      )

    {:ok, signed} = SystemAuthority.sign_capability(cap)
    assert SystemAuthority.verify_capability_signature(signed) == :ok

    {:ok, restored} = Serializer.deserialize(Serializer.serialize(signed))

    assert restored.principal_scope == "human_operator"

    assert SystemAuthority.verify_capability_signature(restored) == :ok,
           "signed cap must still verify after serialize/deserialize"
  end
end
