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
         %{caller: caller, victim_primary: primary, victim_secondary: secondary} do
      grant_manage_cap(caller)

      assert :ok = IdentityAliases.link(caller, secondary, primary)
      assert IdentityAliases.resolve(secondary) == primary

      # Clean up so list_aliases doesn't bleed into other tests
      IdentityAliases.unlink(caller, secondary)
    end

    test "rejects self-aliasing even with manage capability", %{caller: caller} do
      grant_manage_cap(caller)
      assert {:error, :cannot_alias_self} = IdentityAliases.link(caller, "h_x", "h_x")
    end

    test "rejects linking when the primary is itself an alias",
         %{caller: caller, victim_primary: primary, victim_secondary: secondary} do
      grant_manage_cap(caller)

      # Create primary → primary_root chain by linking primary to a third id
      n = System.unique_integer([:positive])
      root = "human_root_m5_#{n}"
      :ok = IdentityAliases.link(caller, primary, root)

      # Now try to link secondary to primary (which is itself aliased)
      result = IdentityAliases.link(caller, secondary, primary)
      assert {:error, {:primary_is_alias, ^root}} = result

      IdentityAliases.unlink(caller, primary)
    end
  end

  describe "unlink/2" do
    test "security regression (M5): unauthorized caller cannot unlink an alias",
         %{caller: caller, victim_primary: primary, victim_secondary: secondary} do
      # Set up an alias as a privileged caller, then try to unlink as
      # an unprivileged one.
      privileged = "human_setup_caller_#{System.unique_integer([:positive])}"
      grant_manage_cap(privileged)

      :ok = IdentityAliases.link(privileged, secondary, primary)
      assert IdentityAliases.resolve(secondary) == primary

      # caller has NOT been granted manage_resource.
      result = IdentityAliases.unlink(caller, secondary)

      assert {:error, {:unauthorized_alias_management, _}} = result,
             "Unauthorized caller must NOT be able to unlink — M5 regression. " <>
               "Got: #{inspect(result)}"

      # Alias still resolves
      assert IdentityAliases.resolve(secondary) == primary

      # Clean up
      IdentityAliases.unlink(privileged, secondary)
    end

    test "authorized caller can unlink",
         %{caller: caller, victim_primary: primary, victim_secondary: secondary} do
      grant_manage_cap(caller)

      :ok = IdentityAliases.link(caller, secondary, primary)
      :ok = IdentityAliases.unlink(caller, secondary)

      assert IdentityAliases.resolve(secondary) == secondary
    end
  end
end
