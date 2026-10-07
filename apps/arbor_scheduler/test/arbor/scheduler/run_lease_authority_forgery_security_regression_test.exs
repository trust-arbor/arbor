defmodule Arbor.Scheduler.RunLeaseAuthorityForgerySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004,SSEC-013"

  @moduletag :fast

  alias Arbor.Scheduler.RunLease

  defmodule StateOwnerStub do
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: RunLease.StateOwner)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:fetch, id}, _from, state) do
      {:reply, Map.fetch(state, id), state}
    end

    def handle_call({:put, id, lease}, _from, state) do
      {:reply, :ok, Map.put(state, id, lease)}
    end

    def handle_call({:delete, id}, _from, state) do
      {:reply, :ok, Map.delete(state, id)}
    end

    def handle_call({:fixture_put, id, lease}, _from, state) do
      {:reply, :ok, Map.put(state, id, lease)}
    end

    def handle_call({:register_identity, _id, _identity, _security}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call({:grant_capability, _id, _opts, _security}, _from, state) do
      {:reply, {:ok, %{id: "cap_stolen"}}, state}
    end

    def handle_call({:open_authority, _id, _identity, _security}, _from, state) do
      {:reply, {:ok, :stolen_signing_authority}, state}
    end
  end

  setup do
    standalone? = is_nil(Process.whereis(RunLease.Store))

    if standalone? do
      start_supervised!(StateOwnerStub)
      store = start_supervised!(RunLease.Store)
      :sys.replace_state(store, &Map.put(&1, :ready, true))
    end

    lease_id = "lease_security_regression_#{System.unique_integer([:positive])}"

    if standalone? do
      lease = %{
        owner: self(),
        creation_token: make_ref(),
        status: :active,
        authority: nil,
        agent_id: nil,
        cap_ids: []
      }

      assert :ok = GenServer.call(RunLease.StateOwner, {:fixture_put, lease_id, lease})
    end

    {:ok, lease_id: lease_id}
  end

  @tag spec: "SSEC-004,SSEC-013"
  test "security regression: forged GenServer from cannot export a run signing authority", %{
    lease_id: lease_id
  } do
    request =
      {:open_authority, lease_id, %{agent_id: "agent_attacker", private_key: :private_key},
       __MODULE__}

    assert {:error, :unauthorized} =
             forged_call(RunLease.Store, self(), request)
  end

  test "security regression: forged GenServer from cannot register a run identity", %{
    lease_id: lease_id
  } do
    request =
      {:register_identity, lease_id,
       %{agent_id: "agent_attacker", private_key: :attacker_private_key}, __MODULE__}

    assert {:error, :unauthorized} = forged_call(RunLease.Store, self(), request)
  end

  test "security regression: forged GenServer from cannot grant a run capability", %{
    lease_id: lease_id
  } do
    request =
      {:grant_capability, lease_id, [principal: "agent_attacker", resource: "arbor://shell/exec"],
       __MODULE__}

    assert {:error, :unauthorized} = forged_call(RunLease.Store, self(), request)
  end

  test "security regression: a lease cannot start without a verified attestation" do
    assert {:error, :verified_attestation_required} =
             RunLease.start(self(),
               ttl_ms: 30_000,
               security_facade: __MODULE__,
               trust_facade: __MODULE__
             )
  end

  test "security regression: legacy lease cleanup-custody rewrite APIs stay removed" do
    refute function_exported?(RunLease, :record_identity, 2)
    refute function_exported?(RunLease, :record_capability, 2)
    refute function_exported?(RunLease, :record_authority, 2)
    refute function_exported?(RunLease.Store, :record, 2)
  end

  def build_signing_authority_acquisition_proof(_agent_id, _private_key, _opts),
    do: {:ok, :forged_proof}

  def open_ephemeral_signing_authority(_proof, _private_key),
    do: {:ok, :stolen_signing_authority}

  defp forged_call(server, claimed_owner, request) do
    test = self()

    spawn(fn ->
      reply_alias = :erlang.alias()
      send(server, {:"$gen_call", {claimed_owner, [:alias | reply_alias]}, request})

      receive do
        {[:alias | ^reply_alias], reply} -> send(test, {:forged_reply, reply})
      after
        5_000 -> send(test, {:forged_reply, :timeout})
      end
    end)

    assert_receive {:forged_reply, reply}, 6_000
    reply
  end
end
