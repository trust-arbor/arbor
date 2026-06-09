defmodule Arbor.Security.CapabilitySignatureCoverageTest do
  @moduledoc """
  **Security regression guard (L2 / crypto-review C1, 2026-06-09).**

  `Capability.signing_payload/1` must cover EVERY security-relevant field the
  authorizer reads. Before v2 it omitted `metadata`, `principal_scope`,
  `allowed_delegatees`, and `parent_capability_id` — so anyone able to mutate
  a stored or in-transit capability (the JSON store backend, a gateway
  boundary) could change those fields without invalidating `issuer_signature`.

  The highest-impact instance: ADD `metadata.provenance` to a signed cap to
  forge the ceiling-bypass marker (`AuthDecision.has_provenance?/1` /
  `pre_approved_bypasses_ceiling?/2`) and skip the askable security ceiling
  for fs/code writes — without ever re-signing.

  This test signs a cap with the real SystemAuthority, then mutates each
  newly-covered field and asserts verification now FAILS. On HEAD~1 (v1
  payload) the metadata/principal_scope/allowed_delegatees/parent forgeries
  still VERIFY; on HEAD they're rejected.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.SystemAuthority

  setup do
    ensure_system_authority_started()

    {:ok, base} =
      Capability.new(
        resource_uri: "arbor://fs/write/Users/x/project/**",
        principal_id: "agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        constraints: %{rate_limit: 10},
        metadata: %{source: "test"}
      )

    {:ok, signed} = SystemAuthority.sign_capability(base)
    # Sanity: the freshly signed cap verifies.
    assert SystemAuthority.verify_capability_signature(signed) == :ok

    {:ok, signed: signed}
  end

  describe "forged field mutations are rejected (v2 payload covers them)" do
    test "adding metadata.provenance is rejected (the ceiling-bypass forgery)",
         %{signed: signed} do
      forged = %{
        signed
        | metadata:
            Map.put(signed.metadata, :provenance, %{source: :caps_file, issuer_id: "agent_evil"})
      }

      refute SystemAuthority.verify_capability_signature(forged) == :ok,
             "adding metadata.provenance must invalidate the signature"
    end

    test "changing any metadata value is rejected", %{signed: signed} do
      forged = %{signed | metadata: Map.put(signed.metadata, :source, "tampered")}
      refute SystemAuthority.verify_capability_signature(forged) == :ok
    end

    test "setting principal_scope (stealing the user binding) is rejected",
         %{signed: signed} do
      forged = %{signed | principal_scope: "human_attacker"}
      refute SystemAuthority.verify_capability_signature(forged) == :ok
    end

    test "widening allowed_delegatees is rejected", %{signed: signed} do
      forged = %{signed | allowed_delegatees: ["agent_evil"]}
      refute SystemAuthority.verify_capability_signature(forged) == :ok
    end

    test "rebinding parent_capability_id is rejected", %{signed: signed} do
      forged = %{signed | parent_capability_id: "cap_other_parent"}
      refute SystemAuthority.verify_capability_signature(forged) == :ok
    end
  end

  describe "legitimate caps still verify (no false rejections)" do
    test "a cap carrying real provenance/scope/delegatees verifies when signed with them" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/write/Users/x/reports/**",
          principal_id: "agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
          principal_scope: "human_operator",
          allowed_delegatees: ["agent_b", "agent_a"],
          metadata: %{provenance: %{source: :caps_file, issuer_id: "agent_issuer"}}
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)
      assert SystemAuthority.verify_capability_signature(signed) == :ok

      # allowed_delegatees order must not matter (set semantics).
      reordered = %{signed | allowed_delegatees: ["agent_a", "agent_b"]}
      assert SystemAuthority.verify_capability_signature(reordered) == :ok
    end

    test "the payload is versioned" do
      assert Capability.signing_version() == "arbor-cap-sig-v2"
    end
  end

  defp ensure_system_authority_started do
    if Process.whereis(SystemAuthority) == nil and Process.whereis(Arbor.Security.Supervisor) do
      for child <- [
            {Arbor.Security.Identity.Registry, []},
            {SystemAuthority, []}
          ] do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            {:error, :already_present} -> :ok
            _ -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end
end
