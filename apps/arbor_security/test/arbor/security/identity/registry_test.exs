defmodule Arbor.Security.Identity.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Identity.Registry

  setup do
    {:ok, identity} = Identity.generate()
    {:ok, identity: identity}
  end

  describe "register/1 and lookup/1" do
    test "round-trip succeeds", %{identity: identity} do
      :ok = Registry.register_fixture(identity)

      assert {:ok, public_key} = Registry.lookup(identity.agent_id)
      assert public_key == identity.public_key
    end

    test "lookup unknown returns :not_found" do
      assert {:error, :not_found} = Registry.lookup("agent_nonexistent")
    end
  end

  describe "register/1 validation" do
    test "security regression: replaceable bound-role fields cannot authorize scheduler, trust or system lifecycle registration" do
      role_pid_keys = [
        :scheduler_identity_pid,
        :trust_capability_grant_owner_pid,
        :system_lifecycle_owner_pid
      ]

      original_role_fields = Registry |> :sys.get_state() |> Map.take(role_pid_keys)

      on_exit(fn ->
        :sys.replace_state(Registry, fn state ->
          state
          |> Map.drop(role_pid_keys)
          |> Map.merge(original_role_fields)
        end)
      end)

      for {pid_key, register} <- [
            {:scheduler_identity_pid, &Registry.register_scheduler_identity/2},
            {:trust_capability_grant_owner_pid,
             &Registry.register_trust_capability_grant_identity/2},
            {:system_lifecycle_owner_pid, &Registry.register_system_lifecycle_identity/2}
          ] do
        attacker = self()
        :sys.replace_state(Registry, &Map.put(&1, pid_key, attacker))

        {:ok, identity} = Identity.generate()
        {:ok, proof} = Registry.registration_proof(identity)

        assert {:error, :identity_registration_unauthorized} = register.(identity, proof)
        assert {:error, :not_found} = Registry.lookup(identity.agent_id)
      end
    end

    test "security regression: public identity registration requires an authenticated actor", %{
      identity: identity
    } do
      public_identity = Identity.public_only(identity)

      assert {:error, :identity_registration_unauthorized} = Registry.register(public_identity)
      assert {:error, :identity_registration_unauthorized} = Registry.register(identity)
      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "security regression: a proof from another identity cannot register an agent", %{
      identity: identity
    } do
      {:ok, attacker} = Identity.generate()
      {:ok, attacker_proof} = Registry.registration_proof(attacker)

      assert {:error, :identity_registration_unauthorized} =
               Registry.register(Identity.public_only(identity), attacker_proof)

      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "rejects mismatched agent_id and public_key" do
      {:ok, identity} = Identity.generate()

      # Tamper with agent_id
      tampered = %{
        identity
        | agent_id: "agent_0000000000000000000000000000000000000000000000000000000000000000"
      }

      assert {:error, :invalid_identity} = Registry.register_fixture(tampered)
    end

    test "rejects duplicate registration", %{identity: identity} do
      :ok = Registry.register_fixture(identity)

      assert {:error, {:already_registered, _}} = Registry.register_fixture(identity)
    end

    test "security regression: ordinary registration rejects human-prefixed identities" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      on_exit(oidc.cleanup)

      assert {:error, :identity_registration_unauthorized} = Registry.register(oidc.identity)
      assert {:error, :not_found} = Registry.lookup(oidc.identity.agent_id)
    end

    test "verified OIDC registration binds identity to verified issuer and subject" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()

      on_exit(fn ->
        oidc.cleanup.()
        _ = Registry.deregister_fixture(oidc.identity.agent_id)
      end)

      assert :ok = Registry.register_oidc(oidc.identity, oidc.id_token, oidc.provider)
      assert {:ok, oidc.identity.public_key} == Registry.lookup(oidc.identity.agent_id)

      other = Arbor.Security.OIDCTestHelper.issue_identity()
      on_exit(other.cleanup)

      assert {:error, {:oidc_identity_mismatch, _, :expected, _}} =
               Registry.register_oidc(oidc.identity, other.id_token, other.provider)
    end
  end

  test "OIDC registration status formatting redacts the signed token" do
    token = "header.payload.sensitive-signature"

    redacted =
      Registry.format_status(%{
        message: {:register_oidc, :identity, token, %{issuer: "https://issuer.test"}},
        reason: {:failed, token},
        log: [token],
        state: %{by_agent_id: %{}, by_name: %{}}
      })

    refute inspect(redacted) =~ token
    assert redacted.message == :redacted
    assert redacted.reason == :redacted
    assert redacted.log == :redacted
  end

  describe "registration policy (C10)" do
    # A policy that denies, reading its verdict + a notify pid from app env so
    # we can also assert it's consulted exactly once (a real policy may consume
    # a one-time enrollment token).
    defmodule TogglePolicy do
      @moduledoc false
      def authorize_registration(_identity, _opts) do
        if pid = Application.get_env(:arbor_security, :test_policy_notify) do
          send(pid, :policy_called)
        end

        Application.get_env(:arbor_security, :test_policy_verdict, :ok)
      end
    end

    defmodule NoCallbackPolicy do
      @moduledoc false
    end

    setup do
      on_exit(fn ->
        Application.delete_env(:arbor_security, :registration_policy)
        Application.delete_env(:arbor_security, :test_policy_verdict)
        Application.delete_env(:arbor_security, :test_policy_notify)
      end)

      :ok
    end

    test "default policy admits only the explicit test fixture path", %{identity: identity} do
      assert :ok = Registry.register_fixture(identity)
    end

    test "a denying policy blocks registration with :registration_denied", %{identity: identity} do
      Application.put_env(:arbor_security, :registration_policy, TogglePolicy)
      Application.put_env(:arbor_security, :test_policy_verdict, {:error, :no_enrollment_token})

      assert {:error, {:registration_denied, :no_enrollment_token}} =
               Registry.register_fixture(identity)

      # And the identity was NOT created.
      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "an allowing policy permits registration and is consulted exactly once",
         %{identity: identity} do
      Application.put_env(:arbor_security, :registration_policy, TogglePolicy)
      Application.put_env(:arbor_security, :test_policy_verdict, :ok)
      Application.put_env(:arbor_security, :test_policy_notify, self())

      assert :ok = Registry.register_fixture(identity)

      # Exactly one consultation — a policy that consumes a one-time token
      # must not be double-charged.
      assert_received :policy_called
      refute_received :policy_called
    end

    test "a misconfigured policy (no callback) fails CLOSED", %{identity: identity} do
      Application.put_env(:arbor_security, :registration_policy, NoCallbackPolicy)

      assert {:error, {:registration_denied, :registration_policy_unavailable}} =
               Registry.register_fixture(identity)
    end

    test "the policy cannot weaken the self-certifying check" do
      # Even with an allow-all policy, a mismatched agent_id is still rejected.
      Application.put_env(:arbor_security, :registration_policy, TogglePolicy)
      Application.put_env(:arbor_security, :test_policy_verdict, :ok)

      {:ok, identity} = Identity.generate()

      tampered = %{
        identity
        | agent_id: "agent_0000000000000000000000000000000000000000000000000000000000000000"
      }

      assert {:error, :invalid_identity} = Registry.register_fixture(tampered)
    end
  end

  describe "registered?/1" do
    test "returns true for registered agent", %{identity: identity} do
      :ok = Registry.register_fixture(identity)
      assert Registry.registered?(identity.agent_id)
    end

    test "returns false for unknown agent" do
      refute Registry.registered?("agent_unknown")
    end
  end

  describe "deregister/1" do
    test "removes identity", %{identity: identity} do
      :ok = Registry.register_fixture(identity)
      assert Registry.registered?(identity.agent_id)

      :ok = Registry.deregister_fixture(identity.agent_id)
      refute Registry.registered?(identity.agent_id)
      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = Registry.deregister_fixture("agent_unknown")
    end
  end

  describe "lookup_by_name/1" do
    test "finds agents by name" do
      {:ok, identity} = Identity.generate(name: "code-reviewer")
      :ok = Registry.register_fixture(identity)

      assert {:ok, [agent_id]} = Registry.lookup_by_name("code-reviewer")
      assert agent_id == identity.agent_id
    end

    test "returns multiple agents with the same name" do
      {:ok, id1} = Identity.generate(name: "worker")
      {:ok, id2} = Identity.generate(name: "worker")
      :ok = Registry.register_fixture(id1)
      :ok = Registry.register_fixture(id2)

      assert {:ok, agent_ids} = Registry.lookup_by_name("worker")
      assert length(agent_ids) == 2
      assert id1.agent_id in agent_ids
      assert id2.agent_id in agent_ids
    end

    test "returns not_found for unknown name" do
      assert {:error, :not_found} = Registry.lookup_by_name("nonexistent")
    end

    test "unnamed agents are not indexed" do
      {:ok, identity} = Identity.generate()
      :ok = Registry.register_fixture(identity)

      # nil name should not be indexed
      assert {:error, :not_found} = Registry.lookup_by_name("nil")
    end
  end

  describe "deregister removes name index" do
    test "name lookup fails after deregister" do
      {:ok, identity} = Identity.generate(name: "temp-agent")
      :ok = Registry.register_fixture(identity)

      assert {:ok, _} = Registry.lookup_by_name("temp-agent")

      :ok = Registry.deregister_fixture(identity.agent_id)

      # Name index should have empty list, returning not_found
      result = Registry.lookup_by_name("temp-agent")
      assert result == {:error, :not_found} or match?({:ok, []}, result)
    end
  end

  describe "stats/0" do
    test "tracks registration counts", %{identity: identity} do
      stats_before = Registry.stats()

      :ok = Registry.register_fixture(identity)

      stats_after = Registry.stats()
      assert stats_after.total_registered == stats_before.total_registered + 1
      assert stats_after.active_identities == stats_before.active_identities + 1
    end
  end
end
