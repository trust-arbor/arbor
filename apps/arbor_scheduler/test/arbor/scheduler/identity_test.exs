defmodule Arbor.Scheduler.IdentityTest do
  @moduledoc """
  Focused checks for the scheduler's reload-stable authority lifecycle.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Scheduler.Identity
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security
  alias Arbor.Trust

  defmodule SecurityFacadeStub do
    def generate_identity(opts) do
      result = Arbor.Security.generate_identity(opts)

      with {:ok, identity} <- result,
           pid when is_pid(pid) <-
             Application.get_env(:arbor_scheduler, :identity_failure_test_pid) do
        send(pid, {:generated_scheduler_identity, identity})
      end

      result
    end

    def register_scheduler_identity(identity, proof) do
      if failure_mode() == :registration,
        do: {:error, :forced_registration_failure},
        else: Arbor.Security.register_scheduler_identity(identity, proof)
    end

    defdelegate lookup_identity_ids_by_display_name(name), to: Arbor.Security
    defdelegate signing_key_status(agent_id), to: Arbor.Security

    def signing_key_public_identity(agent_id),
      do: Arbor.Security.signing_key_public_identity(agent_id)

    defdelegate signing_key_public_identity(agent_id, opts), to: Arbor.Security
    defdelegate migrate_legacy_signing_key_locator(locator, opts), to: Arbor.Security
    defdelegate lookup_public_key(agent_id), to: Arbor.Security
    defdelegate store_signing_key(agent_id, private_key), to: Arbor.Security
    defdelegate delete_signing_key(agent_id), to: Arbor.Security
    defdelegate list_capabilities(agent_id), to: Arbor.Security

    defdelegate build_stored_identity_registration_proof(identity), to: Arbor.Security

    defdelegate build_signing_authority_acquisition_proof(agent_id, private_key, opts),
      to: Arbor.Security

    defdelegate build_stored_signing_authority_acquisition_proof(
                  agent_id,
                  purpose,
                  owner,
                  registered_owner
                ),
                to: Arbor.Security

    def open_signing_authority(proof) do
      if failure_mode() == :authority,
        do: {:error, :forced_authority_failure},
        else: Arbor.Security.open_signing_authority(proof)
    end

    defdelegate close_signing_authority(authority), to: Arbor.Security

    defp failure_mode do
      Application.get_env(:arbor_scheduler, :identity_failure_mode)
    end
  end

  defmodule TrustFacadeStub do
    defdelegate get_trust_profile(agent_id), to: Arbor.Trust
    defdelegate delete_trust_profile(agent_id), to: Arbor.Trust

    def ensure_trust_profile(agent_id, opts) do
      if Application.get_env(:arbor_scheduler, :identity_failure_mode) == :trust,
        do: {:error, :forced_trust_failure},
        else: Arbor.Trust.ensure_trust_profile(agent_id, opts)
    end
  end

  setup do
    stop_identity_if_running()
    cleanup_named_scheduler_identities()

    previous_pid = Application.get_env(:arbor_scheduler, :identity_failure_test_pid, :missing)
    previous_mode = Application.get_env(:arbor_scheduler, :identity_failure_mode, :missing)

    Application.put_env(:arbor_scheduler, :identity_failure_test_pid, self())
    Application.delete_env(:arbor_scheduler, :identity_failure_mode)

    on_exit(fn ->
      restore_env(:identity_failure_test_pid, previous_pid)
      restore_env(:identity_failure_mode, previous_mode)
    end)

    :ok
  end

  describe "agent_id/0 without a running GenServer" do
    test "security regression: returns nil rather than a hardcoded id" do
      # Mirrors the authority contract: no live identity means no
      # caller can spoof one. A hardcoded fallback string would let
      # a misconfigured node masquerade as a valid scheduler.
      refute Process.whereis(Identity), "Identity must not be running in :fast tests"
      assert is_nil(Identity.agent_id())
    end
  end

  test "security regression: stable authority remains private after Identity module reload" do
    {:ok, pid, agent_id} = bootstrap_scheduler_identity()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      cleanup_identity(agent_id)
    end)

    assert is_binary(agent_id)

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)

    state = :sys.get_state(pid)
    status = :sys.get_status(pid)
    refute Enum.any?(Map.values(state), &is_function/1)
    refute contains_signing_authority?(state)
    refute contains_signing_authority?(status)
    assert {:error, :unauthorized} = Security.load_signing_key(agent_id)

    assert_raise ArgumentError, fn ->
      :ets.tab2list(Arbor.Scheduler.Identity.Custody)
    end

    :code.purge(Identity)
    :code.delete(Identity)
    assert Code.ensure_loaded?(Identity)

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)

    assert {:error, :invalid_principal} = Security.signing_key_status("system_scheduler")
  end

  test "security regression: state replacement cannot redirect scheduler authority custody" do
    {:ok, pid, agent_id} = bootstrap_scheduler_identity()
    token = Application.fetch_env!(:arbor_scheduler, :test_scheduler_mutation_token)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      cleanup_identity(agent_id)
    end)

    {:ok, forged_authority} =
      SigningAuthority.new(
        token: :crypto.strong_rand_bytes(32),
        principal_id: agent_id,
        purpose: :scheduler
      )

    hostile_custody = :ets.new(__MODULE__, [:set, :private])

    true =
      :ets.insert(
        hostile_custody,
        {:arbor_scheduler_identity_custody_v1, :ready, forged_authority, Security, token}
      )

    true = :ets.give_away(hostile_custody, pid, :hostile_scheduler_identity_custody)
    assert :ets.info(hostile_custody, :owner) == pid

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:custody, hostile_custody)
      |> Map.put(:signing_authority, forged_authority)
      |> Map.put(:scheduler_mutation_token, token)
    end)

    assert Identity.agent_id() == agent_id
    assert Process.alive?(pid)

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(
               forged_authority,
               "arbor://test/signing/forged-scheduler-custody"
             )

    assert {:error, :scheduler_mutation_unauthorized} =
             Identity.grant_run_capability(
               [principal: agent_id, resource: "arbor://scheduler/foreign-custody"],
               token
             )
  end

  test "fresh identity survives two starts by display name without a legacy key" do
    Security.delete_signing_key_fixture("system_scheduler")

    {:ok, first_pid, agent_id} = bootstrap_scheduler_identity()

    on_exit(fn ->
      stop_identity_if_running()
      cleanup_identity(agent_id)
    end)

    assert {:error, :invalid_principal} = Security.signing_key_status("system_scheduler")
    :ok = GenServer.stop(first_pid, :normal)

    assert {:ok, discovered_ids} = Security.lookup_identity_ids_by_display_name("scheduler")
    assert agent_id in discovered_ids

    {:ok, second_pid} = start_scheduler_identity()
    assert Identity.agent_id() == agent_id

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)

    assert {:error, :invalid_principal} = Security.signing_key_status("system_scheduler")

    assert {:ok, capabilities} = Security.list_capabilities(agent_id)

    assert Enum.count(capabilities, &(&1.resource_uri == "arbor://orchestrator/execute/**")) == 1

    :ok = GenServer.stop(second_pid, :normal)
  end

  test "security regression: legacy registered identity keeps the same principal across restart" do
    {:ok, legacy} = Arbor.Contracts.Security.Identity.generate()
    :ok = Security.store_signing_key_fixture("system_scheduler", legacy.private_key)
    :ok = Security.register_identity_fixture(legacy)

    grant_required_capabilities(legacy.agent_id)

    on_exit(fn ->
      Security.delete_signing_key_fixture("system_scheduler")
      cleanup_identity(legacy.agent_id)
    end)

    {:ok, first_pid} = start_scheduler_identity()
    assert Identity.agent_id() == legacy.agent_id
    :ok = GenServer.stop(first_pid, :normal)

    {:ok, second_pid} = start_scheduler_identity()
    assert Identity.agent_id() == legacy.agent_id

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)

    :ok = GenServer.stop(second_pid, :normal)
  end

  test "fresh registration failure removes only the principal key created by the attempt" do
    Application.put_env(:arbor_scheduler, :identity_failure_mode, :registration)

    assert {:error, {:identity_registration_failed, :forced_registration_failure}} =
             start_identity_expect_error(
               security_facade: SecurityFacadeStub,
               trust_facade: TrustFacadeStub
             )

    assert_receive {:generated_scheduler_identity, identity}
    assert {:error, :no_signing_key} = Security.signing_key_status(identity.agent_id)
    assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)
    assert {:error, :invalid_principal} = Security.signing_key_status("system_scheduler")
  end

  test "security regression: arbitrary caller cannot use the scheduler bootstrap API" do
    {:ok, identity} = Arbor.Contracts.Security.Identity.generate(name: "forged scheduler")
    {:ok, proof} = Security.build_identity_registration_proof_fixture(identity)

    assert {:error, :identity_registration_unauthorized} =
             Security.register_scheduler_identity(identity, proof)

    assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)
  end

  test "security regression: scheduler authority is not an ambient mutation deputy" do
    {:ok, pid, agent_id} = bootstrap_scheduler_identity()
    token = Application.fetch_env!(:arbor_scheduler, :test_scheduler_mutation_token)
    resource = "arbor://scheduler/security-regression/#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GenServer.stop(pid, :normal)
      cleanup_identity(agent_id)
    end)

    assert {:error, :scheduler_mutation_unauthorized} =
             Identity.grant_run_capability(
               [principal: agent_id, resource: resource],
               token
             )

    assert {:ok, capabilities} = Security.list_capabilities(agent_id)
    refute Enum.any?(capabilities, &(&1.resource_uri == resource))
  end

  test "security regression: forged GenServer callers and raw messages cannot drive Identity" do
    {:ok, pid, agent_id} = bootstrap_scheduler_identity()
    token = Application.fetch_env!(:arbor_scheduler, :test_scheduler_mutation_token)
    resource = "arbor://scheduler/forged-call/#{System.unique_integer([:positive])}"
    state_owner = Process.whereis(Arbor.Scheduler.RunLease.StateOwner)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      cleanup_identity(agent_id)
    end)

    request = {:grant_run_capability, [principal: agent_id, resource: resource], token}

    assert {:error, :scheduler_mutation_unauthorized} = GenServer.call(pid, request)

    assert {:error, :scheduler_mutation_unauthorized} =
             forged_call(pid, state_owner, request)

    GenServer.cast(pid, request)
    send(pid, :forged_identity_control)
    assert :ok = Identity.await_ready()

    assert Process.whereis(Identity) == pid
    assert Process.alive?(pid)
    assert {:ok, capabilities} = Security.list_capabilities(agent_id)
    refute Enum.any?(capabilities, &(&1.resource_uri == resource))
  end

  test "security regression: missing scheduler authority stays dormant and never self-grants" do
    # A fresh install has no operator grant yet. The identity must neither
    # crash the scheduler application (that blocked every fresh boot) nor
    # mint its own authority; it waits, dormant, for an operator.
    assert {:error,
            {:scheduler_identity_dormant,
             {:capability_provision_failed,
              {:scheduler_capability_not_provisioned, "arbor://orchestrator/execute/**"}}}} =
             start_scheduler_identity()

    pid = Process.whereis(Identity)
    assert is_pid(pid) and Process.alive?(pid)

    assert {:ok, [agent_id]} = Security.lookup_identity_ids_by_display_name("scheduler")
    on_exit(fn -> cleanup_identity(agent_id) end)

    assert {:ok, public_key} = Security.lookup_public_key(agent_id)
    assert is_binary(public_key)
    assert {:ok, :available} = Security.signing_key_status(agent_id)

    assert %{
             state: :dormant,
             principal_id: ^agent_id,
             missing_capabilities: missing
           } = Identity.status()

    assert missing == Identity.required_capability_uris()
    assert Identity.agent_id() == agent_id

    # Re-checking without an operator grant stays dormant and grants nothing.
    assert {:error, {:scheduler_identity_dormant, _reason}} = Identity.retry_bootstrap()
    assert {:ok, capabilities} = Security.list_capabilities(agent_id)
    assert capabilities == []

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)

    grant_required_capabilities(agent_id)

    assert :ok = Identity.retry_bootstrap()
    assert Process.whereis(Identity) == pid
    assert %{state: :ready, principal_id: ^agent_id, missing_capabilities: []} = Identity.status()

    assert {:error, :scheduler_authority_not_exported} =
             GenServer.call(Identity, :get_signing_authority)

    :ok = GenServer.stop(pid, :normal)
  end

  defp cleanup_identity(agent_id) do
    Security.revoke_all_fixture(agent_id)
    Trust.delete_trust_profile(agent_id)
    Security.delete_signing_key_fixture(agent_id)
    Security.deregister_identity_fixture(agent_id)
    :ok
  end

  defp cleanup_named_scheduler_identities do
    case Security.lookup_identity_ids_by_display_name("scheduler") do
      {:ok, agent_ids} -> Enum.each(agent_ids, &cleanup_identity/1)
      _ -> :ok
    end
  end

  defp stop_identity_if_running do
    case Process.whereis(Identity) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  defp start_scheduler_identity(opts \\ []) do
    spec = Supervisor.child_spec({Identity, opts}, restart: :temporary)

    case Supervisor.start_child(Arbor.Scheduler.Supervisor, spec) do
      {:ok, pid} ->
        case Identity.await_ready() do
          :ok -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  defp bootstrap_scheduler_identity(opts \\ []) do
    missing_capability =
      {:capability_provision_failed,
       {:scheduler_capability_not_provisioned, "arbor://orchestrator/execute/**"}}

    with {:error, {:scheduler_identity_dormant, ^missing_capability}} <-
           start_scheduler_identity(opts),
         {:ok, [agent_id]} <- Security.lookup_identity_ids_by_display_name("scheduler"),
         :ok <- grant_required_capabilities(agent_id),
         :ok <- Identity.retry_bootstrap(),
         pid when is_pid(pid) <- Process.whereis(Identity) do
      {:ok, pid, agent_id}
    end
  end

  defp grant_required_capabilities(agent_id) do
    Enum.reduce_while(Identity.required_capability_uris(), :ok, fn resource, :ok ->
      case Security.grant_fixture(principal: agent_id, resource: resource) do
        {:ok, _capability} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_identity_expect_error(opts) do
    previous = Process.flag(:trap_exit, true)

    try do
      start_scheduler_identity(opts)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp forged_call(server, claimed_caller, request) do
    test = self()

    spawn(fn ->
      reply_alias = :erlang.alias()
      send(server, {:"$gen_call", {claimed_caller, [:alias | reply_alias]}, request})

      receive do
        {[:alias | ^reply_alias], reply} -> send(test, {:forged_identity_reply, reply})
      after
        5_000 -> send(test, {:forged_identity_reply, :timeout})
      end
    end)

    assert_receive {:forged_identity_reply, reply}, 6_000
    reply
  end

  defp restore_env(key, :missing), do: Application.delete_env(:arbor_scheduler, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_scheduler, key, value)

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
