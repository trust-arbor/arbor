defmodule Arbor.Security.AuthorityStoreCallCycleSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestAuditConsumer

  setup do
    # The polling consumer also sends store calls. Pause it so mailbox length
    # is a barrier for the calls this fixture starts.
    :ok = :sys.suspend(TestAuditConsumer)
    on_exit(fn -> :ok = :sys.resume(TestAuditConsumer) end)

    {:ok, actor} = Identity.generate()
    {:ok, target} = Identity.generate()
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)

    on_exit(fn ->
      for principal <- [actor.agent_id, target.agent_id] do
        Security.revoke_all_fixture(principal)
        Security.deregister_identity_fixture(principal)
      end
    end)

    resource = "arbor://fs/read/call-cycle"

    assert {:ok, capability} =
             Security.grant_fixture(principal: target.agent_id, resource: resource)

    assert {:ok, right} =
             Security.grant_fixture(
               principal: actor.agent_id,
               resource: "arbor://security/revoke/#{target.agent_id}"
             )

    store = Process.whereis(CapabilityStore)
    assert is_pid(store)

    %{actor: actor, target: target, capability: capability, right: right, store: store}
  end

  test "security regression: revocation and a signature-checking store read both complete", ctx do
    %{actor: actor, target: target, capability: capability, store: store} = ctx
    resource = capability.resource_uri
    assert {:ok, ^capability} = CapabilityStore.find_authorizing(target.agent_id, resource)
    assert is_binary(capability.issuer_signature)

    reader =
      Task.async(fn ->
        receive do
          :read -> timed(fn -> CapabilityStore.find_authorizing(target.agent_id, resource) end)
        end
      end)

    revoker = start_revoker(actor, target.agent_id)

    # Put the signature-checking read ahead of the revocation's authority lookup.
    # Resume only when both calls are queued. The store mailbox remains sensitive.
    :ok = :sys.suspend(store)

    try do
      send(reader.pid, :read)
      await_queued_calls(store, 1)
      send(revoker.pid, :revoke)
      await_queued_calls(store, 2)
    after
      :ok = :sys.resume(store)
    end

    {read_result, read_ms} = Task.await(reader, 7_000)
    {revoke_result, revoke_ms} = Task.await(revoker, 7_000)

    assert read_ms < 2_000 and revoke_ms < 2_000,
           "read took #{read_ms} ms (#{inspect(result_kind(read_result))}), " <>
             "revocation took #{revoke_ms} ms (#{inspect(revoke_result)})"

    assert {:ok, ^capability} = read_result
    assert {:ok, 1} = revoke_result
    assert {:error, :not_found} = CapabilityStore.get(capability.id)
  end

  test "security regression: a removed revocation right invalidates a pending decision", ctx do
    %{actor: actor, target: target, capability: capability, right: right, store: store} = ctx
    authority = Process.whereis(SystemAuthority)
    assert is_pid(authority)
    revoker = start_revoker(actor, target.agent_id)

    :ok = :sys.suspend(store)

    try do
      send(revoker.pid, :revoke)
      await_queued_calls(store, 1)
      :ok = :sys.suspend(authority, 2_000)
    after
      :ok = :sys.resume(store)
    end

    try do
      # The lookup was already queued. The store serves it before removing
      # the right, while the authority cannot yet act on the reply.
      assert :ok = Security.revoke_fixture(right.id)
    after
      :ok = :sys.resume(authority)
    end

    assert {{:error, :capability_revocation_unauthorized}, elapsed_ms} = Task.await(revoker)
    assert elapsed_ms < 2_000
    assert {:ok, ^capability} = CapabilityStore.get(capability.id)
  end

  defp start_revoker(actor, target_id) do
    parent = self()

    task =
      Task.async(fn ->
        {:ok, proof} =
          Security.build_signing_authority_acquisition_proof(actor.agent_id, actor.private_key,
            purpose: :authority_store_call_cycle
          )

        {:ok, authority} = Security.open_ephemeral_signing_authority(proof, actor.private_key)
        send(parent, {:revoker_ready, self()})

        receive do
          :revoke -> timed(fn -> Security.revoke_all(target_id, actor_authority: authority) end)
        end
      end)

    assert_receive {:revoker_ready, pid}, 2_000
    assert pid == task.pid
    task
  end

  defp await_queued_calls(store, count) do
    assert wait_for_queue(store, count, System.monotonic_time(:millisecond) + 2_000),
           "expected #{count} calls in CapabilityStore's suspended mailbox, got #{inspect(Process.info(store, :message_queue_len))}"
  end

  defp wait_for_queue(store, count, deadline) do
    case Process.info(store, :message_queue_len) do
      {:message_queue_len, queued} when queued >= count ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_for_queue(store, count, deadline)
        else
          false
        end
    end
  end

  defp result_kind({:ok, _capability}), do: :ok
  defp result_kind(error), do: error

  defp timed(operation) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        operation.()
      catch
        :exit, {:timeout, _call} -> {:error, :timeout}
      end

    {result, System.monotonic_time(:millisecond) - started}
  end
end
