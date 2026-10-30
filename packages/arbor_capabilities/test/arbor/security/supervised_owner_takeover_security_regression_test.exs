defmodule Arbor.Security.SupervisedOwnerTakeoverSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-004"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security.{
    ApprovalReceiptBroker,
    CapabilityStore,
    DeliveryReceiptBroker,
    IssuerRegistry,
    MasterKeyAccessOwner,
    SessionRegistry,
    SigningAuthorityBroker,
    SigningAuthorityStateOwner,
    SystemAuthority
  }

  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.OIDC.{JwksCache, TokenCacheOwner}

  @supervisor Arbor.Security.Supervisor

  @tag spec: "SSEC-002,SSEC-004"
  test "security regression: authority directories cannot be reclaimed by live squatters" do
    cases = [
      {SystemAuthority, :arbor_security_system_authority_directory, fn pid -> {:owner, pid} end,
       fn -> SystemAuthority.public_key() end},
      {SigningAuthorityBroker, :arbor_security_signing_authority_broker_directory,
       fn pid -> {:owner, pid} end, fn -> SigningAuthorityBroker.debug_state() end},
      {ApprovalReceiptBroker, :arbor_security_approval_receipt_broker_owner,
       fn pid -> {:owner_pid, pid} end,
       fn ->
         ApprovalReceiptBroker.verify(
           %{},
           "human_takeover",
           "arbor://test/takeover",
           :execute,
           String.duplicate("0", 64)
         )
       end},
      {SessionRegistry, :arbor_security_session_registry_owner, fn pid -> {:owner_pid, pid} end,
       fn -> SessionRegistry.active?(String.duplicate("0", 32), "human_takeover") end},
      {DeliveryReceiptBroker, :arbor_security_delivery_receipt_broker_directory,
       fn pid -> {:owner, pid} end, fn -> DeliveryReceiptBroker.stats() end},
      {CapabilityStore, :arbor_security_capability_store_owner_directory,
       fn pid -> {:owner, pid, false, <<0::256>>} end,
       fn -> CapabilityStore.get("cap_takeover") end},
      {Registry, :arbor_security_identity_registry_owner_directory, fn pid -> {:owner, pid} end,
       fn -> Registry.lookup("agent_" <> String.duplicate("0", 64)) end},
      {IssuerRegistry, :arbor_security_issuer_registry_owner_directory,
       fn pid -> {:owner, pid} end,
       fn -> IssuerRegistry.lookup("agent_" <> String.duplicate("1", 64)) end},
      {MasterKeyAccessOwner, :arbor_security_master_key_access_owner_directory,
       fn pid -> {:owner, pid} end,
       fn -> MasterKeyAccessOwner.authenticate(make_ref(), :authority_record, "chosen") end},
      {TokenCacheOwner, :arbor_security_oidc_token_cache_owner_directory,
       fn pid -> {:owner, pid} end, fn -> TokenCacheOwner.load() end},
      {JwksCache, :arbor_oidc_jwks_cache, nil, fn -> JwksCache.get_or_fetch(%{}) end}
    ]

    Enum.each(cases, fn {child, table, row_builder, probe} ->
      assert_squatter_rejected(child, table, row_builder, probe)
    end)
  end

  test "security regression: signing state-owner directory cannot be reclaimed" do
    stop_child(SigningAuthorityBroker)
    stop_child(SigningAuthorityStateOwner)

    try do
      with_squatter(
        SigningAuthorityStateOwner,
        :arbor_security_signing_authority_state_owner_directory,
        fn pid -> {:owner, pid} end,
        fn ->
          result = closed_result(fn -> SigningAuthorityStateOwner.load(make_ref()) end)
          refute result == :forged
          refute_receive {:owner_squatter_called, SigningAuthorityStateOwner, _request}, 50
        end
      )
    after
      restart_child(SigningAuthorityStateOwner)
      restart_child(SigningAuthorityBroker)
    end
  end

  defp assert_squatter_rejected(child, table, row_builder, probe) do
    stop_child(child)

    try do
      with_squatter(child, table, row_builder, fn ->
        result = closed_result(probe)
        refute result == :forged
        refute_receive {:owner_squatter_called, ^child, _request}, 50
      end)
    after
      restart_child(child)
    end
  end

  defp with_squatter(child, table, row_builder, assertion) do
    parent = self()

    squatter =
      spawn(fn ->
        _table = :ets.new(table, [:named_table, :protected, :set])
        if is_function(row_builder, 1), do: true = :ets.insert(table, row_builder.(self()))
        send(parent, {:owner_squatter_ready, child, self()})
        squatter_loop(parent, child)
      end)

    assert_receive {:owner_squatter_ready, ^child, ^squatter}, 1_000

    try do
      assertion.()
    after
      ref = Process.monitor(squatter)
      send(squatter, :stop)

      receive do
        {:DOWN, ^ref, :process, ^squatter, _reason} -> :ok
      after
        1_000 -> Process.exit(squatter, :kill)
      end
    end
  end

  defp squatter_loop(parent, child) do
    receive do
      {:"$gen_call", from, request} ->
        send(parent, {:owner_squatter_called, child, request})
        GenServer.reply(from, :forged)
        squatter_loop(parent, child)

      :stop ->
        :ok

      message ->
        send(parent, {:owner_squatter_called, child, message})
        squatter_loop(parent, child)
    end
  end

  defp closed_result(fun) do
    fun.()
  rescue
    _ -> :closed
  catch
    :exit, _ -> :closed
    _, _ -> :closed
  end

  defp stop_child(child) do
    case Supervisor.terminate_child(@supervisor, child) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restart_child(child) do
    case Supervisor.restart_child(@supervisor, child) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
    end
  end
end
