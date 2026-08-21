defmodule Arbor.Agent.IdentityAliasesTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.IdentityAliases

  @manage_resource "arbor://identity/alias/manage"

  setup_all do
    # This module authorizes via Arbor.Security with unsigned test capabilities
    # and unsigned authorize calls, so it needs signing/strict-identity OFF. Set
    # these explicitly rather than trusting the global default — a combined
    # umbrella run can have them in force (the full Security tree is started),
    # which broke the alias grant/deny tests with identity/signing errors. Tests
    # here are async: false, so this holds; restore prior values on exit.
    prev_security =
      for key <- [:capability_signing_required, :strict_identity_mode, :identity_verification] do
        {key, Application.get_env(:arbor_security, key)}
      end

    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :identity_verification, false)

    on_exit(fn ->
      for {key, value} <- prev_security do
        if is_nil(value),
          do: Application.delete_env(:arbor_security, key),
          else: Application.put_env(:arbor_security, key, value)
      end
    end)

    # arbor_agent's app supervisor doesn't bring up Arbor.Security on test
    # boot — but our M5 fix authorizes against Arbor.Security.CapabilityStore.
    # Start the minimum chain needed for authorize/4 to actually run.
    buffered_store = Arbor.Persistence.BufferedStore

    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {buffered_store,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, _} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      Supervisor.start_child(Arbor.Security.Supervisor, child)
    end

    # IdentityAliases persists into the :arbor_user_config BufferedStore, which
    # isn't part of the test_helper boot sequence. Start it via start_supervised
    # (tied to THIS module — cleaned up when the module finishes) rather than the
    # persistent AppSupervisor. The old AppSupervisor.start_child LEAKED the
    # globally-named process for the rest of the suite, so depending on test order
    # it collided with UserConfigTest's start_supervised! of the same name
    # (:already_started) and made the suite flaky by seed. Both tests are
    # async: false, so they never run concurrently — each owns a clean store.
    start_supervised!(
      Supervisor.child_spec(
        {Arbor.Persistence.BufferedStore,
         name: :arbor_user_config,
         backend: Arbor.Security.Store.JSONFile,
         write_mode: :sync,
         collection: "user_config"},
        id: :arbor_user_config
      )
    )

    :ok
  end

  setup do
    # Per-test unique caller / identity ids so we don't collide with sibling
    # tests in the same OS process.
    n = System.unique_integer([:positive])

    %{
      caller: "human_caller_m5_#{n}",
      victim_primary: "human_victim_primary_m5_#{n}",
      victim_secondary: "human_victim_secondary_m5_#{n}",
      attacker_secondary: "human_attacker_alias_m5_#{n}"
    }
  end

  defp grant_manage_cap(principal) do
    now = DateTime.utc_now()

    cap = %Arbor.Contracts.Security.Capability{
      id: "cap_alias_manage_#{principal}_#{System.unique_integer([:positive])}",
      principal_id: principal,
      resource_uri: @manage_resource,
      granted_at: now,
      expires_at: DateTime.add(now, 3600, :second)
    }

    Arbor.Security.CapabilityStore.put(cap)
  end

  defp registered_principal do
    {:ok, identity} = Arbor.Security.generate_identity()
    :ok = Arbor.Security.register_identity(identity)
    identity
  end

  defp signed_manage(identity) do
    {:ok, signed} =
      Arbor.Agent.IdentityAliasProof.sign(%{
        agent_id: identity.agent_id,
        private_key: identity.private_key
      })

    signed
  end

  defp cleanup_principal(identity, secondary_ids \\ []) do
    Enum.each(List.wrap(secondary_ids), fn secondary ->
      case Arbor.Agent.IdentityAliasProof.sign(%{
             agent_id: identity.agent_id,
             private_key: identity.private_key
           }) do
        {:ok, signed} ->
          _ = IdentityAliases.unlink(identity.agent_id, secondary, signed_request: signed)

        _ ->
          :ok
      end
    end)

    _ = Arbor.Security.delete_signing_key(identity.agent_id)
    _ = Arbor.Security.deregister_identity(identity.agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  describe "link/3" do
    test "security regression (M5): unauthorized caller cannot create an alias",
         %{caller: caller, victim_primary: victim, attacker_secondary: attacker} do
      # M5: pre-fix, IdentityAliases.link/2 checked only self-aliasing and
      # circular alias chains. Anyone who could call it could redirect a
      # victim's OIDC logins to an attacker-controlled identity, then collect
      # whatever capabilities had been granted to the victim's primary id.
      # The fix requires the caller to hold arbor://identity/alias/manage.

      # Caller has NOT been granted manage_resource.
      result = IdentityAliases.link(caller, attacker, victim)

      assert {:error, {:unauthorized_alias_management, _}} = result,
             "Unauthorized caller must NOT be able to link an alias — M5 regression. " <>
               "Got: #{inspect(result)}"

      # And the alias must not have been created — resolve should return self.
      assert IdentityAliases.resolve(attacker) == attacker,
             "Alias persisted despite unauthorized caller — M5 regression"
    end

    test "authorized caller can create an alias",
         %{victim_primary: primary, victim_secondary: secondary} do
      identity = registered_principal()
      caller = identity.agent_id
      grant_manage_cap(caller)

      {link_result, resolved} =
        try do
          result =
            IdentityAliases.link(caller, secondary, primary,
              signed_request: signed_manage(identity)
            )

          {result, IdentityAliases.resolve(secondary)}
        after
          cleanup_principal(identity, secondary)
        end

      assert :ok = link_result
      assert resolved == primary
    end

    test "rejects self-aliasing even with manage capability" do
      identity = registered_principal()
      caller = identity.agent_id
      grant_manage_cap(caller)

      result =
        try do
          IdentityAliases.link(caller, "h_x", "h_x", signed_request: signed_manage(identity))
        after
          cleanup_principal(identity)
        end

      assert {:error, :cannot_alias_self} = result
    end

    test "rejects linking when the primary is itself an alias",
         %{victim_primary: primary, victim_secondary: secondary} do
      identity = registered_principal()
      caller = identity.agent_id
      grant_manage_cap(caller)

      n = System.unique_integer([:positive])
      root = "human_root_m5_#{n}"

      result =
        try do
          :ok =
            IdentityAliases.link(caller, primary, root, signed_request: signed_manage(identity))

          IdentityAliases.link(caller, secondary, primary, signed_request: signed_manage(identity))
        after
          cleanup_principal(identity, [primary, secondary])
        end

      assert {:error, {:primary_is_alias, ^root}} = result
    end
  end

  describe "unlink/2" do
    test "security regression (M5): unauthorized caller cannot unlink an alias",
         %{caller: caller, victim_primary: primary, victim_secondary: secondary} do
      privileged_identity = registered_principal()
      privileged = privileged_identity.agent_id
      grant_manage_cap(privileged)

      {unlink_result, still_aliased} =
        try do
          :ok =
            IdentityAliases.link(privileged, secondary, primary,
              signed_request: signed_manage(privileged_identity)
            )

          assert IdentityAliases.resolve(secondary) == primary

          result = IdentityAliases.unlink(caller, secondary)
          {result, IdentityAliases.resolve(secondary)}
        after
          cleanup_principal(privileged_identity, secondary)
        end

      assert {:error, {:unauthorized_alias_management, _}} = unlink_result,
             "Unauthorized caller must NOT be able to unlink — M5 regression. " <>
               "Got: #{inspect(unlink_result)}"

      assert still_aliased == primary
    end

    test "authorized caller can unlink",
         %{victim_primary: primary, victim_secondary: secondary} do
      identity = registered_principal()
      caller = identity.agent_id
      grant_manage_cap(caller)

      resolved =
        try do
          :ok =
            IdentityAliases.link(caller, secondary, primary,
              signed_request: signed_manage(identity)
            )

          :ok =
            IdentityAliases.unlink(caller, secondary,
              signed_request: signed_manage(identity)
            )

          IdentityAliases.resolve(secondary)
        after
          cleanup_principal(identity, secondary)
        end

      assert resolved == secondary
    end
  end

  describe "possession-proof authorization" do
    test "proof-backed caller with the capability can link" do
      identity = registered_principal()
      caller = identity.agent_id
      grant_manage_cap(caller)
      n = System.unique_integer([:positive])
      secondary = "human_proof_sec_#{n}"
      primary = "human_proof_pri_#{n}"

      {link_result, resolved} =
        try do
          result =
            IdentityAliases.link(caller, secondary, primary,
              signed_request: signed_manage(identity)
            )

          {result, IdentityAliases.resolve(secondary)}
        after
          cleanup_principal(identity, secondary)
        end

      assert :ok = link_result
      assert resolved == primary
    end

    test "valid proof without the capability is a capability denial, not a proof failure" do
      identity = registered_principal()
      caller = identity.agent_id
      n = System.unique_integer([:positive])
      secondary = "human_nocap_sec_#{n}"
      primary = "human_nocap_pri_#{n}"

      result =
        try do
          IdentityAliases.link(caller, secondary, primary, signed_request: signed_manage(identity))
        after
          cleanup_principal(identity, secondary)
        end

      assert {:error, {:unauthorized_alias_management, :unauthorized}} = result
      assert IdentityAliases.resolve(secondary) == secondary
    end

    test "capability without a produced proof is a proof failure" do
      identity = registered_principal()
      caller = identity.agent_id
      grant_manage_cap(caller)
      n = System.unique_integer([:positive])
      secondary = "human_noproof_sec_#{n}"
      primary = "human_noproof_pri_#{n}"

      result =
        try do
          IdentityAliases.link(caller, secondary, primary)
        after
          cleanup_principal(identity, secondary)
        end

      assert {:error, {:unauthorized_alias_management, :missing_signed_request}} = result
      assert IdentityAliases.resolve(secondary) == secondary
    end

    test "security regression: naming another stored-key principal cannot exercise alias-management" do
      # The rejected design loaded the named principal's SigningKeyStore key
      # and signed on its behalf. This test stores the victim's key, grants
      # the capability, then names the victim WITHOUT a client-produced
      # SignedRequest. A server-signs-for-you implementation would return :ok.
      victim = registered_principal()
      :ok = Arbor.Security.store_signing_key(victim.agent_id, victim.private_key)
      grant_manage_cap(victim.agent_id)

      n = System.unique_integer([:positive])
      secondary = "human_impersonation_sec_#{n}"
      primary = "human_impersonation_pri_#{n}"

      result =
        try do
          IdentityAliases.link(victim.agent_id, secondary, primary)
        after
          cleanup_principal(victim, secondary)
        end

      assert {:error, {:unauthorized_alias_management, :missing_signed_request}} = result,
             "Naming a stored-key principal must not exercise its " <>
               "alias-management capability. Got: #{inspect(result)}"

      assert IdentityAliases.resolve(secondary) == secondary
    end

    test "security regression: a proof for a different principal cannot be used as the victim" do
      victim = registered_principal()
      attacker = registered_principal()
      :ok = Arbor.Security.store_signing_key(victim.agent_id, victim.private_key)
      grant_manage_cap(victim.agent_id)

      n = System.unique_integer([:positive])
      secondary = "human_mismatch_sec_#{n}"
      primary = "human_mismatch_pri_#{n}"

      result =
        try do
          IdentityAliases.link(victim.agent_id, secondary, primary,
            signed_request: signed_manage(attacker)
          )
        after
          cleanup_principal(victim, secondary)
          cleanup_principal(attacker)
        end

      assert {:error, {:unauthorized_alias_management, {:identity_mismatch, _, _}}} = result
      assert IdentityAliases.resolve(secondary) == secondary
    end
  end
end

