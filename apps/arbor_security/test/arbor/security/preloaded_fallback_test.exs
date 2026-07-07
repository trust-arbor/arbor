defmodule Arbor.Security.PreloadedFallbackTest do
  @moduledoc """
  **Security regression guards (M2 + L1 review fixes, 2026-06-09).**

  When the CapabilityStore is unavailable and strict mode is off,
  `AuthDecision.find_matching_capability/2` falls back to the capabilities
  carried on the AuthContext (`try_preloaded_capabilities/2`).

  - **M2:** that fallback used to match on URI ALONE — no signature check,
    no expiry check — so a store outage became a signature bypass: any
    unsigned/expired preloaded cap was honored. It now applies the same
    gates as the primary path (validity + signature acceptability).
  - **L1:** the fallback's old private `/**` branch used a bare `starts_with?`
    with no segment boundary, so a cap `arbor://agent/profile/agent_X/**`
    matched `…/agent_XEVIL/...`. It now uses the same shared capability URI
    matcher as the primary store path.

  The store outage is simulated via the `:capability_store_module` seam
  (a stub whose `find_authorizing/2` raises) so the fallback is reached
  deterministically — the real store is supervised with permanent restart
  and can't be reliably kept down.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{AuthContext, Capability}
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.SystemAuthority

  defmodule CrashingStore do
    @moduledoc false
    def find_authorizing(_principal, _resource),
      do: raise("simulated CapabilityStore outage")
  end

  setup do
    ensure_security_started()

    prev = %{
      store: Application.get_env(:arbor_security, :capability_store_module),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      delegation: Application.get_env(:arbor_security, :delegation_chain_verification_enabled)
    }

    # Force the store-unavailable fallback, non-strict, no interfering gates.
    Application.put_env(:arbor_security, :capability_store_module, CrashingStore)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :delegation_chain_verification_enabled, false)

    on_exit(fn ->
      restore(:capability_store_module, prev.store)
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
      restore(:delegation_chain_verification_enabled, prev.delegation)
    end)

    {:ok, agent_id: "agent_preload_#{:erlang.unique_integer([:positive])}"}
  end

  describe "preloaded fallback re-verifies signatures (M2)" do
    setup do
      Application.put_env(:arbor_security, :capability_signing_required, true)
      :ok
    end

    # The fallback's decision is accept (cap found → {:ok, _, _, _}, possibly
    # gated downstream) vs reject (cap not honored → {:error, :unauthorized, _}).
    # Trust isn't started here, so a found cap surfaces as :requires_approval
    # (no profile → default :ask) — that still means the fallback HONORED it,
    # which is exactly what M2 must prevent for an unsigned cap.

    test "UNSIGNED preloaded cap is REJECTED when signing is required", %{agent_id: agent_id} do
      uri = "arbor://historian/query"
      cap = unsigned_cap(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert match?({:error, :unauthorized, _}, AuthDecision.evaluate(auth, uri, :query)),
             "unsigned preloaded cap must be rejected by the fallback under signing-required"
    end

    test "SIGNED preloaded cap is HONORED by the fallback", %{agent_id: agent_id} do
      uri = "arbor://historian/query"
      cap = signed_cap(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      result = AuthDecision.evaluate(auth, uri, :query)

      refute match?({:error, :unauthorized, _}, result),
             "signed preloaded cap must be honored by the fallback; got #{inspect(result)}"

      assert match?({:ok, _, _, _}, result)
    end
  end

  describe "preloaded fallback matcher respects segment boundary (L1)" do
    setup do
      # Isolate the matcher boundary from the signature gate.
      Application.put_env(:arbor_security, :capability_signing_required, false)
      :ok
    end

    test "sibling-prefix resource does NOT match a /** cap", %{agent_id: agent_id} do
      cap = unsigned_cap(agent_id, "arbor://agent/profile/agent_X/**")
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      # agent_XEVIL shares the textual prefix "agent_X" but is a different
      # segment — the fallback matcher must REJECT it (no boundary bleed).
      result = AuthDecision.evaluate(auth, "arbor://agent/profile/agent_XEVIL/secret", :read)

      assert match?({:error, :unauthorized, _}, result),
             "sibling-prefix must NOT match across the segment boundary; got #{inspect(result)}"
    end

    test "genuine subtree resource DOES match a /** cap", %{agent_id: agent_id} do
      cap = unsigned_cap(agent_id, "arbor://agent/profile/agent_X/**")
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      result = AuthDecision.evaluate(auth, "arbor://agent/profile/agent_X/secret", :read)

      refute match?({:error, :unauthorized, _}, result),
             "genuine subtree must be honored by the fallback; got #{inspect(result)}"

      assert match?({:ok, _, _, _}, result)
    end
  end

  defp unsigned_cap(agent_id, uri) do
    %Capability{
      id: "cap_pf_#{:erlang.unique_integer([:positive])}",
      resource_uri: uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{}
    }
  end

  defp signed_cap(agent_id, uri) do
    {:ok, cap} = Capability.new(resource_uri: uri, principal_id: agent_id)
    {:ok, signed} = SystemAuthority.sign_capability(cap)
    signed
  end

  defp ensure_security_started do
    children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- children do
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

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)
end
