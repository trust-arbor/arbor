defmodule Arbor.Trust.CapabilityGrantOwnerSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004"

  @moduletag :fast

  alias Arbor.Contracts.Security.{
    Capability,
    CapabilityUri,
    Identity,
    SignedRequest,
    SigningAuthority
  }

  alias Arbor.Trust.{CapabilityGrantOwner, CapabilityGrantRequest}

  defmodule FakeSecurity.State do
    use Agent

    def start_link(initial_state),
      do: Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  defmodule FakeSecurity do
    alias Arbor.Contracts.Security.{Capability, Identity, SigningAuthority}

    def lookup_identity_ids_by_display_name(_name) do
      {:ok, [state().owner_identity.agent_id]}
    end

    def signing_key_public_identity(_principal_id, _opts) do
      {:ok, Identity.public_only(state().owner_identity)}
    end

    def lookup_public_key(principal_id) do
      owner = state().owner_identity

      if principal_id == owner.agent_id,
        do: {:ok, owner.public_key},
        else: Arbor.Security.lookup_public_key(principal_id)
    end

    def list_capabilities(_principal_id) do
      if state().provisioned do
        {:ok, [state().provisioning_capability]}
      else
        {:ok, []}
      end
    end

    def authorize(_principal_id, _resource_uri, :execute, _opts) do
      if state().authorization_live,
        do: {:ok, :authorized},
        else: {:error, :unauthorized}
    end

    def build_stored_signing_authority_acquisition_proof(
          _principal_id,
          :trust_capability_grant,
          owner,
          Arbor.Trust.CapabilityGrantOwner
        )
        when owner == self(),
        do: {:ok, :owner_bound_proof}

    def open_signing_authority(:owner_bound_proof) do
      SigningAuthority.new(
        token: :crypto.strong_rand_bytes(32),
        principal_id: state().owner_identity.agent_id,
        purpose: :trust_capability_grant
      )
    end

    def close_signing_authority(%SigningAuthority{}), do: :ok

    def verify_request(request), do: Arbor.Security.verify_request(request)

    def grant(opts) do
      send(state().test_pid, {:grant_called, opts})

      Capability.new(
        principal_id: Keyword.fetch!(opts, :principal),
        resource_uri: Keyword.fetch!(opts, :resource),
        constraints: Keyword.get(opts, :constraints, %{}),
        session_id: Keyword.get(opts, :session_id),
        metadata: Keyword.get(opts, :metadata, %{})
      )
    end

    defp state, do: Agent.get(__MODULE__.State, & &1)
  end

  defmodule FakePolicy do
    def grant_spec(_principal_id, _resource_uri, _opts) do
      case Agent.get(
             Arbor.Trust.CapabilityGrantOwnerSecurityRegressionTest.FakeSecurity.State,
             & &1.policy_mode
           ) do
        :block ->
          {:error, :unauthorized}

        mode when mode in [:ask, :allow, :auto] ->
          {:ok,
           %{
             mode: mode,
             constraints: %{},
             profile: %{
               uri_prefix: "arbor://fs/read",
               effect_class: :read,
               blast_radius: :low,
               reversibility: :read_only,
               default_approval: :allow
             }
           }}
      end
    end
  end

  defmodule ProductionOwnerSupervisor do
    use Supervisor

    def start_link(_opts) do
      Supervisor.start_link(__MODULE__, :ok, name: Arbor.Trust.Supervisor)
    end

    @impl true
    def init(:ok), do: Supervisor.init([{CapabilityGrantOwner, []}], strategy: :one_for_one)
  end

  setup do
    test_pid = self()
    {:ok, owner_identity} = Identity.generate(name: "test-trust-grant-owner")

    {:ok, provisioning_capability} =
      Capability.new(
        principal_id: owner_identity.agent_id,
        resource_uri: CapabilityGrantOwner.required_capability_uri()
      )

    start_supervised!(
      {FakeSecurity.State,
       %{
         test_pid: test_pid,
         owner_identity: owner_identity,
         provisioning_capability: provisioning_capability,
         provisioned: true,
         authorization_live: true,
         policy_mode: :auto
       }}
    )

    {:ok, target} = Identity.generate(name: "jit-target")
    :ok = Arbor.Security.register_identity_fixture(target)

    on_exit(fn ->
      _ = Arbor.Security.deregister_identity_fixture(target.agent_id)
    end)

    {:ok, target: target}
  end

  @tag spec: "SSEC-004"
  test "security regression: grant payload is a bounded canonical CapabilityUri", %{
    target: target
  } do
    resource = "arbor://fs/read/project/docs"
    session_id = "session/canonical grant"

    assert {:ok, request, payload} =
             CapabilityGrantRequest.build(target.agent_id, resource, session_id)

    assert byte_size(payload) <= 2_048
    assert {:ok, parsed} = CapabilityUri.parse(payload)
    assert CapabilityUri.canonical(parsed) == payload
    assert {:ok, ^request} = CapabilityGrantRequest.decode(payload)
    assert request.target_agent_id == target.agent_id
    assert request.resource_uri == resource
    assert request.session_id == session_id
  end

  test "security regression: forged target and resource are denied", %{target: signer} do
    {:ok, forged_target} = Identity.generate(name: "forged-target")
    :ok = Arbor.Security.register_identity_fixture(forged_target)

    on_exit(fn ->
      _ = Arbor.Security.deregister_identity_fixture(forged_target.agent_id)
    end)

    owner = start_owner!()

    assert {:ok, _request, target_payload} =
             CapabilityGrantRequest.build(
               forged_target.agent_id,
               "arbor://fs/read/target-forgery",
               "session-target-forgery"
             )

    assert {:ok, forged_target_request} =
             SignedRequest.sign(target_payload, signer.agent_id, signer.private_key)

    assert {:error, :capability_grant_request_denied} =
             CapabilityGrantOwner.request(forged_target_request, owner)

    refute_received {:grant_called, _opts}

    assert {:ok, _request, original_payload} =
             CapabilityGrantRequest.build(
               signer.agent_id,
               "arbor://fs/read/original",
               "session-resource-forgery"
             )

    assert {:ok, signed_original} =
             SignedRequest.sign(original_payload, signer.agent_id, signer.private_key)

    tampered_payload =
      String.replace(
        original_payload,
        Base.url_encode64("arbor://fs/read/original", padding: false),
        Base.url_encode64("arbor://fs/read/forged", padding: false)
      )

    assert tampered_payload != original_payload
    assert {:ok, _tampered_request} = CapabilityGrantRequest.decode(tampered_payload)

    assert {:error, :capability_grant_request_denied} =
             CapabilityGrantOwner.request(%{signed_original | payload: tampered_payload}, owner)

    refute_received {:grant_called, _opts}
  end

  test "security regression: grant requests are one-use and blocked requests consume their nonce",
       %{target: target} do
    owner = start_owner!()
    signed = signed_request!(target, "arbor://fs/read/one-use", "session-one-use")

    assert {:ok, capability} = CapabilityGrantOwner.request(signed, owner)
    assert capability.principal_id == target.agent_id
    assert capability.resource_uri == "arbor://fs/read/one-use"
    assert capability.session_id == "session-one-use"

    assert_receive {:grant_called, grant_opts}
    assert %SigningAuthority{} = grant_opts[:actor_authority]

    assert {:error, :capability_grant_request_replayed} =
             CapabilityGrantOwner.request(signed, owner)

    refute_received {:grant_called, _opts}

    set_state(:policy_mode, :block)
    blocked = signed_request!(target, "arbor://fs/read/blocked", "session-blocked")

    assert {:error, :capability_grant_request_denied} =
             CapabilityGrantOwner.request(blocked, owner)

    assert {:error, :capability_grant_request_replayed} =
             CapabilityGrantOwner.request(blocked, owner)

    refute_received {:grant_called, _opts}
  end

  test "security regression: owner stays dormant without a live operator provision", %{
    target: target
  } do
    set_state(:provisioned, false)
    owner = start_owner!()

    assert %{state: :dormant, principal_id: principal_id} = CapabilityGrantOwner.status(owner)
    assert is_binary(principal_id)

    signed = signed_request!(target, "arbor://fs/read/unprovisioned", "session-unprovisioned")

    assert {:error, :capability_grant_owner_unprovisioned} =
             CapabilityGrantOwner.request(signed, owner)

    refute_received {:grant_called, _opts}

    set_state(:provisioned, true)
    set_state(:authorization_live, false)
    assert :ok = stop_supervised(CapabilityGrantOwner)
    owner = start_owner!()
    assert %{state: :dormant} = CapabilityGrantOwner.status(owner)

    assert {:error, :capability_grant_owner_unprovisioned} =
             CapabilityGrantOwner.request(signed, owner)

    refute_received {:grant_called, _opts}
  end

  test "security regression: raw owner control messages are denied without restarting custody" do
    owner = start_owner!()

    assert {:error, :capability_grant_owner_unauthorized} = GenServer.call(owner, :reload)

    GenServer.cast(owner, :reload)
    send(owner, :reload)
    Process.sleep(10)

    assert Process.alive?(owner)
    assert %{state: :ready} = CapabilityGrantOwner.status(owner)
  end

  test "security regression: state inspection and replacement cannot expose or redirect grant authority",
       %{target: target} do
    owner = start_owner!()
    state = :sys.get_state(owner)
    status = :sys.get_status(owner)

    refute contains_signing_authority?(state)
    refute contains_signing_authority?(status)

    assert_raise ArgumentError, fn ->
      :ets.tab2list(Arbor.Trust.CapabilityGrantOwner.Custody)
    end

    {:ok, forged_authority} =
      SigningAuthority.new(
        token: :crypto.strong_rand_bytes(32),
        principal_id: target.agent_id,
        purpose: :trust_capability_grant
      )

    hostile_custody = :ets.new(__MODULE__, [:set, :private])

    true =
      :ets.insert(
        hostile_custody,
        {:arbor_trust_capability_grant_owner_custody_v1, :ready, FakeSecurity, FakePolicy, 8_192,
         forged_authority, %{}}
      )

    true = :ets.give_away(hostile_custody, owner, :hostile_grant_owner_custody)
    assert :ets.info(hostile_custody, :owner) == owner

    :sys.replace_state(owner, fn current ->
      current
      |> Map.put(:custody, hostile_custody)
      |> Map.put(:authority, forged_authority)
      |> Map.put(:security, FakeSecurity)
      |> Map.put(:policy, FakePolicy)
    end)

    signed = signed_request!(target, "arbor://fs/read/custody", "session-custody")
    assert {:ok, _capability} = CapabilityGrantOwner.request(signed, owner)
    assert_receive {:grant_called, grant_opts}
    assert %SigningAuthority{} = real_authority = grant_opts[:actor_authority]
    refute real_authority.token == forged_authority.token

    assert {:error, :authority_not_found} =
             Arbor.Security.sign_with_authority(
               forged_authority,
               "arbor://test/signing/forged-trust-custody"
             )
  end

  test "security regression: nonce capacity fails closed before a second grant", %{target: target} do
    owner = start_owner!(nonce_capacity: 1)
    first = signed_request!(target, "arbor://fs/read/capacity-one", "session-capacity")
    second = signed_request!(target, "arbor://fs/read/capacity-two", "session-capacity")

    assert {:ok, _capability} = CapabilityGrantOwner.request(first, owner)
    assert_receive {:grant_called, _opts}

    assert {:error, :capability_grant_request_capacity} =
             CapabilityGrantOwner.request(second, owner)

    refute_received {:grant_called, _opts}

    assert {:error, :capability_grant_request_capacity} =
             CapabilityGrantOwner.request(second, owner)

    refute_received {:grant_called, _opts}
  end

  test "security regression: supervised grant owner bootstraps after exact child admission" do
    refute Process.whereis(Arbor.Trust.Supervisor)
    refute Process.whereis(CapabilityGrantOwner)

    spec =
      Supervisor.child_spec({ProductionOwnerSupervisor, []},
        id: Arbor.Trust.Supervisor,
        restart: :temporary
      )

    assert {:ok, supervisor} =
             Supervisor.start_child(Arbor.Trust.ApplicationSupervisor, spec)

    on_exit(fn ->
      if Process.alive?(supervisor) do
        _ = Supervisor.terminate_child(Arbor.Trust.ApplicationSupervisor, Arbor.Trust.Supervisor)
        _ = Supervisor.delete_child(Arbor.Trust.ApplicationSupervisor, Arbor.Trust.Supervisor)
      end
    end)

    status = CapabilityGrantOwner.status()
    assert status.state in [:ready, :dormant]
    assert is_binary(status.principal_id)
    refute match?({:identity_creation_failed, :key_store_unavailable}, status.reason)
    assert {:ok, :available} = Arbor.Security.signing_key_status(status.principal_id)
    assert {:ok, _public_key} = Arbor.Security.lookup_public_key(status.principal_id)
  end

  defp start_owner!(opts \\ []) do
    start_supervised!(
      {CapabilityGrantOwner,
       [
         name: nil,
         security_facade: FakeSecurity,
         policy_enforcer: FakePolicy,
         nonce_capacity: Keyword.get(opts, :nonce_capacity, 8_192)
       ]}
    )
  end

  defp signed_request!(identity, resource_uri, session_id) do
    assert {:ok, _request, payload} =
             CapabilityGrantRequest.build(identity.agent_id, resource_uri, session_id)

    assert {:ok, signed_request} =
             SignedRequest.sign(payload, identity.agent_id, identity.private_key)

    signed_request
  end

  defp set_state(key, value) do
    Agent.update(FakeSecurity.State, &Map.put(&1, key, value))
  end

  defp contains_signing_authority?(%SigningAuthority{}), do: true

  defp contains_signing_authority?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      contains_signing_authority?(key) or contains_signing_authority?(value)
    end)
  end

  defp contains_signing_authority?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.any?(&contains_signing_authority?/1)
  end

  defp contains_signing_authority?(term) when is_list(term),
    do: Enum.any?(term, &contains_signing_authority?/1)

  defp contains_signing_authority?(_term), do: false
end
