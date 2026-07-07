defmodule Arbor.Agent.TrustPresetApplyTest do
  @moduledoc """
  Security-regression guard for commit 7721f506.

  A data-first `.md` template that declares a `trust_preset` must get that
  restrictive trust profile APPLIED to the agent at create time. Before the fix,
  `Lifecycle.apply_template_trust_preset/2` only fired for the legacy module
  `trust_preset/0` callback — so data-first templates silently fell back to the
  default (`:cautious` → baseline `:ask`) profile with none of the declared rules.
  The read-only-by-default agent roster would have shipped WIDE OPEN.

  Test 1 is the guard: create an agent from a template whose frontmatter declares
  `baseline: block` + read-only rules, read its trust profile, and assert the
  restrictive baseline + rules landed. Comment out the
  `apply_template_trust_preset(agent_id, opts)` call in `Lifecycle.ensure_trust_profile/2`
  and this test fails — the baseline reverts to the default `:ask`.

  Test 2 proves the preset path only fires when a preset is declared: a template
  with no `trust_preset` keeps the default `:ask` baseline and is NOT forced to
  `:block`.

  ## Test-env setup notes

  `arbor_agent`'s app supervisor does not bring up Security or Trust on test boot
  (`config :arbor_security/:arbor_trust, start_children: false`). This test starts
  the exact chain `Lifecycle.create/2` exercises: the Security identity ceremony +
  signing-key store (mirroring `IdentityAliasesTest`), the agent profile store
  (mirroring `ReconcilerTest` / `ManagerTest`), and Trust `Store` + `Manager`
  (`ensure_trust_profile` reads via `Arbor.Trust.get_trust_profile`, and
  `apply_template_trust_preset` writes via `Arbor.Trust.Store.update_profile`).
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arbor.Agent.Lifecycle
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Trust.Store, as: TrustStore

  @profiles_store :arbor_agent_profiles

  setup_all do
    # This test creates identities and grants capabilities with unsigned test
    # crypto, so it needs signing / strict-identity / verification OFF. Set these
    # explicitly rather than trusting the global default — a combined umbrella run
    # can have them in force. async: false, so a per-suite set holds; restore on
    # exit.
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

    :ok
  end

  setup do
    # --- Security: the identity ceremony + signing-key persistence create/2 runs.
    # BufferedStores back the identity / signing-key / capability stores; the
    # GenServers below do the work. Added under the already-running (empty)
    # Arbor.Security.Supervisor, tolerating already-started for combined runs.
    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      start_security_child(
        Supervisor.child_spec(
          {BufferedStore,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )
      )
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      start_security_child(child)
    end

    # --- Agent profile store: create/2 persists the Profile here (persist_profile).
    if Process.whereis(@profiles_store) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end

    # --- Trust: Store (ETS profile cache) + Manager. ensure_trust_profile reads via
    # Manager (Arbor.Trust.get_trust_profile); apply_template_trust_preset writes via
    # Trust.Store.update_profile. Optional components disabled — not needed here, and
    # they pull in EventStore/persistence we don't want in this isolated env.
    if Process.whereis(TrustStore) == nil do
      start_supervised!({TrustStore, []})
    end

    if Process.whereis(Arbor.Trust.Manager) == nil do
      start_supervised!(
        {Arbor.Trust.Manager, [circuit_breaker: false, decay: false, event_store: false]}
      )
    end

    :ok
  end

  describe "trust_preset applied at create time (security regression, commit 7721f506)" do
    test "a data-first template's declarative trust_preset lands on the agent's trust profile" do
      assert {:ok, profile} = Lifecycle.create("Test Agent Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, tp} = TrustStore.get_profile(agent_id)

      # THE GUARD. Without apply_template_trust_preset firing for data-first
      # templates, baseline would be the default :ask and none of these rules
      # would be present.
      assert tp.baseline == :block
      # Bare-prefix rules (trust rules match by prefix, not glob — see
      # Arbor.Contracts.Security.TrustRule; templates are bare as of 59fa2cef and the
      # normalize path canonicalizes any glob form to bare regardless).
      assert tp.rules["arbor://fs/read"] == :allow
      assert tp.rules["arbor://fs/list"] == :allow
      assert tp.rules["arbor://orchestrator/execute"] == :allow
    end

    test "template orchestrator grant covers mandatory per-node middleware checks" do
      assert {:ok, profile} = Lifecycle.create("Middleware Gate Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute", :execute)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute/exec", :execute)
    end

    test "a template WITHOUT a trust_preset is not forced to :block by this path" do
      assert {:ok, profile} =
               Lifecycle.create("Plain Agent Probe", template: "conversationalist")

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, tp} = TrustStore.get_profile(agent_id)

      # Keeps the default (:cautious) profile — baseline :ask, NOT forced to
      # :block. Proves the preset path only fires when a preset is declared.
      assert tp.baseline == :ask
      refute tp.baseline == :block
    end
  end

  # --- helpers ---

  defp start_security_child(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, _} -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp cleanup(agent_id) do
    on_exit(fn ->
      try do
        Lifecycle.destroy(agent_id)
      catch
        _, _ -> :ok
      end
    end)
  end
end
