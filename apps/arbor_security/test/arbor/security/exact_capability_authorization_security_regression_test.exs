defmodule Arbor.Security.ExactCapabilityAuthorizationSecurityRegressionTest do
  @moduledoc """
  Security regression coverage for exact ordinary capability authorization.

  Exact mode is required by the Voice egress lifecycle: revoking an intended
  session-bound route capability must not be hidden by a second broad or
  unbound capability for the same resource.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.{CapabilityStore, DisclosureCapability, SystemAuthority}
  alias Arbor.Security.Identity.Registry

  @authority_key {__MODULE__, :actor_authority}

  @moduletag :fast
  @moduletag security: :regression

  setup do
    previous = %{
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :identity_verification),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled)
    }

    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)

    {:ok, actor} = Identity.generate(name: "exact-capability-actor")
    :ok = Registry.register_fixture(actor)
    target = "agent_" <> String.duplicate("a", 32)

    {:ok, mutation_cap} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/grant/#{target}"
      )

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        actor.agent_id,
        actor.private_key,
        purpose: :exact_capability_authorization_test
      )

    {:ok, actor_authority} =
      Security.open_ephemeral_signing_authority(proof, actor.private_key)

    Process.put(@authority_key, actor_authority)

    on_exit(fn ->
      Security.close_signing_authority(actor_authority)
      Security.revoke_fixture(mutation_cap.id)
      Security.deregister_identity_fixture(actor.agent_id)
      restore(:capability_signing_required, previous.signing)
      restore(:identity_verification, previous.identity)
      restore(:uri_registry_enforcement, previous.uri)
      restore(:reflex_checking_enabled, previous.reflex)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)

  defp unique, do: System.unique_integer([:positive])

  defp fixture do
    n = unique()

    %{
      principal: "agent_" <> String.duplicate("a", 32),
      resource: "arbor://test/exact_capability_#{n}",
      session_id: "session_#{n}",
      task_id: "task_#{n}",
      principal_scope: "human_#{n}",
      expires_at: nil
    }
  end

  defp grant!(attrs) do
    assert {:ok, cap} =
             Security.grant_fixture(
               principal: attrs.principal,
               resource: attrs.resource,
               session_id: Map.get(attrs, :session_id),
               task_id: Map.get(attrs, :task_id),
               principal_scope: Map.get(attrs, :principal_scope),
               expires_at: Map.get(attrs, :expires_at)
             )

    on_exit(fn -> _ = Security.revoke_fixture(cap.id) end)
    cap
  end

  defp exact_opts(cap, attrs, overrides \\ []) do
    [
      exact_capability_id: cap.id,
      session_id: attrs.session_id,
      task_id: attrs.task_id,
      principal_scope: attrs.principal_scope
    ]
    |> Keyword.merge(overrides)
  end

  describe "security regression: exact ordinary capability selection" do
    test "security regression: revoked intended capability cannot be replaced by an unbound covering cap" do
      attrs = fixture()
      intended = grant!(attrs)
      :ok = Security.revoke_fixture(intended.id)

      substitute =
        grant!(%{attrs | session_id: nil, task_id: nil, principal_scope: nil})

      assert {:ok, :authorized} = Security.authorize(attrs.principal, attrs.resource, :connect)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(intended, attrs)
               )

      assert substitute.id != intended.id
    end

    test "security regression: mixed and string exact option keys cannot fall back to a substitute" do
      attrs = fixture()
      intended = grant!(attrs)
      :ok = Security.revoke_fixture(intended.id)
      _substitute = grant!(%{attrs | session_id: nil, task_id: nil, principal_scope: nil})

      for opts <- [
            [{"session_id", attrs.session_id}, exact_capability_id: intended.id],
            [{"exact_capability_id", intended.id}]
          ] do
        assert {:error, :invalid_exact_capability_id} =
                 Security.authorize(attrs.principal, attrs.resource, :connect, opts)
      end
    end

    test "security regression: map and tuple exact option containers fail closed" do
      attrs = fixture()
      cap = grant!(attrs)

      for opts <- [
            %{exact_capability_id: cap.id},
            %{"exact_capability_id" => cap.id},
            {:exact_capability_id, cap.id}
          ] do
        assert {:error, :invalid_exact_capability_id} =
                 Security.authorize(attrs.principal, attrs.resource, :connect, opts)
      end
    end

    test "security regression: exact signed capability authorizes with its complete scope" do
      attrs = fixture()
      cap = grant!(attrs)

      assert {:ok, :authorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(cap, attrs)
               )
    end

    test "security regression: wrong id principal resource or wildcard cap denies" do
      attrs = fixture()
      cap = grant!(attrs)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(cap, attrs, exact_capability_id: "cap_" <> String.duplicate("b", 32))
               )

      assert {:error, :unauthorized} =
               Security.authorize(
                 "agent_" <> String.duplicate("c", 32),
                 attrs.resource,
                 :connect,
                 exact_opts(cap, attrs)
               )

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource <> "/other",
                 :connect,
                 exact_opts(cap, attrs)
               )

      wildcard = grant!(%{attrs | resource: attrs.resource <> "/**"})

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(wildcard, attrs)
               )
    end

    test "security regression: exact scope equality rejects omitted wrong and extra bindings" do
      attrs = fixture()
      cap = grant!(attrs)

      for opts <- [
            Keyword.delete(exact_opts(cap, attrs), :session_id),
            exact_opts(cap, attrs, session_id: "other_session"),
            exact_opts(cap, attrs, task_id: "other_task"),
            exact_opts(cap, attrs, principal_scope: "human_other"),
            exact_opts(cap, attrs, session_id: nil)
          ] do
        assert {:error, :unauthorized} =
                 Security.authorize(attrs.principal, attrs.resource, :connect, opts)
      end

      session_only = grant!(%{attrs | task_id: nil, principal_scope: nil})

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_capability_id: session_only.id,
                 session_id: attrs.session_id,
                 task_id: attrs.task_id
               )
    end

    test "security regression: expired revoked unsigned invalid-chain and disclosure capabilities deny" do
      attrs = fixture()
      now = DateTime.utc_now()

      {:ok, expired} =
        Capability.new(
          resource_uri: attrs.resource,
          principal_id: attrs.principal,
          session_id: attrs.session_id,
          task_id: attrs.task_id,
          principal_scope: attrs.principal_scope,
          granted_at: DateTime.add(now, -2, :second),
          expires_at: DateTime.add(now, -1, :second)
        )

      {:ok, expired} = SystemAuthority.sign_capability_for_test(expired)
      assert {:ok, :stored} = CapabilityStore.put_fixture(expired)
      on_exit(fn -> _ = Security.revoke_fixture(expired.id) end)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(expired, attrs)
               )

      revoked = grant!(attrs)
      :ok = Security.revoke_fixture(revoked.id)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(revoked, attrs)
               )

      {:ok, unsigned} =
        Capability.new(
          resource_uri: attrs.resource,
          principal_id: attrs.principal,
          session_id: attrs.session_id,
          task_id: attrs.task_id,
          principal_scope: attrs.principal_scope
        )

      assert {:ok, :stored} = CapabilityStore.put_fixture(unsigned)
      on_exit(fn -> _ = Security.revoke_fixture(unsigned.id) end)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(unsigned, attrs)
               )

      {:ok, signed_invalid_chain} =
        unsigned
        |> Map.put(:id, "cap_" <> String.duplicate("d", 32))
        |> Map.put(:delegation_chain, [%{forged: true}])
        |> SystemAuthority.sign_capability_for_test()

      assert {:ok, :stored} = CapabilityStore.put_fixture(signed_invalid_chain)
      on_exit(fn -> _ = Security.revoke_fixture(signed_invalid_chain.id) end)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(signed_invalid_chain, attrs)
               )

      assert {:ok, disclosure} =
               DisclosureCapability.issue(
                 principal_id: attrs.principal,
                 session_id: attrs.session_id,
                 task_id: attrs.task_id,
                 principal_scope: attrs.principal_scope,
                 destination: "api.example.test",
                 provider: "example",
                 runtime: "arbor",
                 actor_authority: Process.get(@authority_key)
               )

      on_exit(fn -> _ = Security.revoke_fixture(disclosure.id) end)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 disclosure.resource_uri,
                 :connect,
                 exact_opts(disclosure, attrs)
               )
    end

    test "security regression: system-signed parent capability without a chain denies" do
      attrs = fixture()
      cap = grant!(attrs)

      {:ok, parent_without_chain} =
        cap
        |> Map.put(:id, "cap_" <> String.duplicate("e", 32))
        |> Map.put(:parent_capability_id, "cap_" <> String.duplicate("f", 32))
        |> Map.put(:delegation_chain, [])
        |> SystemAuthority.sign_capability_for_test()

      assert {:ok, :stored} = CapabilityStore.put_fixture(parent_without_chain)
      on_exit(fn -> _ = Security.revoke_fixture(parent_without_chain.id) end)

      assert {:error, :unauthorized} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(parent_without_chain, attrs)
               )
    end

    test "security regression: duplicate and malformed exact capability options fail closed" do
      attrs = fixture()
      cap = grant!(attrs)

      assert {:error, :invalid_exact_capability_id} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(cap, attrs) ++ [exact_capability_id: cap.id]
               )

      assert {:error, :invalid_exact_capability_id} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(cap, attrs, exact_capability_id: "bad id\t")
               )

      {:ok, malformed_id_cap} =
        cap
        |> Map.put(:id, "cap_" <> String.duplicate("g", 32))
        |> SystemAuthority.sign_capability_for_test()

      assert {:error, _reason} = CapabilityStore.put_fixture(malformed_id_cap)
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)

      assert {:error, :invalid_exact_capability_scope} =
               Security.authorize(
                 attrs.principal,
                 attrs.resource,
                 :connect,
                 exact_opts(cap, attrs) ++ [session_id: attrs.session_id]
               )
    end
  end
end
