defmodule Arbor.Scheduler.IdentityTest do
  @moduledoc """
  Focused checks for the scheduler's reload-stable authority lifecycle.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Scheduler.Identity
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

    def register_identity(identity) do
      if failure_mode() == :registration,
        do: {:error, :forced_registration_failure},
        else: Arbor.Security.register_identity(identity)
    end

    def grant(opts) do
      if failure_mode() == :capability,
        do: {:error, :forced_capability_failure},
        else: Arbor.Security.grant(opts)
    end

    defdelegate lookup_identity_ids_by_display_name(name), to: Arbor.Security
    defdelegate load_signing_key(agent_id), to: Arbor.Security
    defdelegate lookup_public_key(agent_id), to: Arbor.Security
    defdelegate store_signing_key(agent_id, private_key), to: Arbor.Security
    defdelegate delete_signing_key(agent_id), to: Arbor.Security
    defdelegate deregister_identity(agent_id), to: Arbor.Security
    defdelegate list_capabilities(agent_id), to: Arbor.Security
    defdelegate revoke(capability_id), to: Arbor.Security

    defdelegate build_signing_authority_acquisition_proof(agent_id, private_key, opts),
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

  describe "authority without a running GenServer" do
    test "security regression: returns nil rather than a permissive fallback" do
      refute Process.whereis(Identity), "Identity must not be running in :fast tests"
      assert is_nil(Identity.signing_authority())
    end
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

  test "security regression: stable authority signs after Identity module reload" do
    {:ok, pid} = Identity.start_link()
    agent_id = Identity.agent_id()
    authority = Identity.signing_authority()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      cleanup_identity(agent_id)
    end)

    assert is_binary(agent_id)
    assert authority.principal_id == agent_id
    assert {:ok, _} = Security.sign_with_authority(authority, "before-reload")
    assert {:ok, private_key} = Security.load_signing_key(agent_id)

    state = :sys.get_state(pid)
    refute Enum.any?(Map.values(state), &is_function/1)
    refute :binary.match(:erlang.term_to_binary(state), private_key) != :nomatch

    :code.purge(Identity)
    :code.delete(Identity)
    assert Code.ensure_loaded?(Identity)

    assert {:ok, _} = Security.sign_with_authority(Identity.signing_authority(), "after-reload")
    assert {:error, :no_signing_key} = Security.load_signing_key("system_scheduler")
  end

  test "fresh identity survives two starts by display name without a legacy key" do
    Security.delete_signing_key("system_scheduler")

    {:ok, first_pid} = Identity.start_link()
    agent_id = Identity.agent_id()

    on_exit(fn ->
      stop_identity_if_running()
      cleanup_identity(agent_id)
    end)

    assert {:error, :no_signing_key} = Security.load_signing_key("system_scheduler")
    :ok = GenServer.stop(first_pid, :normal)

    assert {:ok, discovered_ids} = Security.lookup_identity_ids_by_display_name("scheduler")
    assert agent_id in discovered_ids

    {:ok, second_pid} = Identity.start_link()
    assert Identity.agent_id() == agent_id
    assert Identity.signing_authority().principal_id == agent_id
    assert {:error, :no_signing_key} = Security.load_signing_key("system_scheduler")

    assert {:ok, capabilities} = Security.list_capabilities(agent_id)

    assert Enum.count(capabilities, &(&1.resource_uri == "arbor://orchestrator/execute/**")) == 1

    :ok = GenServer.stop(second_pid, :normal)
  end

  test "security regression: legacy registered identity keeps the same principal across restart" do
    {:ok, legacy} = Arbor.Contracts.Security.Identity.generate()
    :ok = Security.store_signing_key("system_scheduler", legacy.private_key)
    :ok = Security.register_identity(legacy)

    on_exit(fn ->
      Security.delete_signing_key("system_scheduler")
      cleanup_identity(legacy.agent_id)
    end)

    {:ok, first_pid} = Identity.start_link()
    assert Identity.agent_id() == legacy.agent_id
    :ok = GenServer.stop(first_pid, :normal)

    {:ok, second_pid} = Identity.start_link()
    assert Identity.agent_id() == legacy.agent_id
    assert Identity.signing_authority().principal_id == legacy.agent_id
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
    assert {:error, :no_signing_key} = Security.load_signing_key(identity.agent_id)
    assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)
    assert {:error, :no_signing_key} = Security.load_signing_key("system_scheduler")
  end

  test "capability, trust, and authority failures roll back fresh identity provisioning" do
    for {mode, expected_error} <- [
          {:capability, {:capability_provision_failed, :forced_capability_failure}},
          {:trust, {:trust_profile_provision_failed, :forced_trust_failure}},
          {:authority, {:signing_authority_open_failed, :forced_authority_failure}}
        ] do
      Application.put_env(:arbor_scheduler, :identity_failure_mode, mode)

      assert {:error, ^expected_error} =
               start_identity_expect_error(
                 security_facade: SecurityFacadeStub,
                 trust_facade: TrustFacadeStub
               )

      assert_receive {:generated_scheduler_identity, identity}
      assert {:error, :no_signing_key} = Security.load_signing_key(identity.agent_id)
      assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)
      assert {:ok, []} = Security.list_capabilities(identity.agent_id)
      assert {:error, :not_found} = Trust.get_trust_profile(identity.agent_id)
    end
  end

  test "failed provisioning does not delete a pre-existing named identity or key" do
    {:ok, existing} = Arbor.Contracts.Security.Identity.generate(name: "scheduler")
    :ok = Security.store_signing_key(existing.agent_id, existing.private_key)
    :ok = Security.register_identity(existing)

    on_exit(fn -> cleanup_identity(existing.agent_id) end)

    Application.put_env(:arbor_scheduler, :identity_failure_mode, :capability)

    assert {:error, {:capability_provision_failed, :forced_capability_failure}} =
             start_identity_expect_error(
               security_facade: SecurityFacadeStub,
               trust_facade: TrustFacadeStub
             )

    assert {:ok, existing.private_key} == Security.load_signing_key(existing.agent_id)
    assert {:ok, existing.public_key} == Security.lookup_public_key(existing.agent_id)
  end

  defp cleanup_identity(agent_id) do
    case Security.list_capabilities(agent_id) do
      {:ok, capabilities} -> Enum.each(capabilities, &Security.revoke(&1.id))
      _ -> :ok
    end

    Trust.delete_trust_profile(agent_id)
    Security.delete_signing_key(agent_id)
    Security.deregister_identity(agent_id)
    :ok
  end

  defp stop_identity_if_running do
    case Process.whereis(Identity) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  defp start_identity_expect_error(opts) do
    previous = Process.flag(:trap_exit, true)

    try do
      Identity.start_link(opts)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp restore_env(key, :missing), do: Application.delete_env(:arbor_scheduler, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_scheduler, key, value)
end
